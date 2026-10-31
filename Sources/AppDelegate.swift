import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let menu = NSMenu()

    private var snapshot = MemorySnapshot()
    private var report = ProcessReport()
    private let cpuMonitor = CPUMonitor()

    private var cleanupWindow: CleanupWindowController?
    private var lastAlert: Date?
    private var lastDiskAlert: Date?
    private let alertCooldown: TimeInterval = 10 * 60
    private var wasCritical = false

    private let refreshInterval: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Tout est dessiné dans l'image (voir Gauge.statusImage) : pas de titre texte.
        // VoiceOver lit donc le nom ici et les mesures dans la valeur, mise à jour à chaque relevé.
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Jauge RAM")
        statusItem.button?.toolTip = tr("Pression mémoire")

        menu.delegate = self
        statusItem.menu = menu

        requestNotificationPermission()
        refresh()

        // Pas en mode diagnostic : lancé hors du .app installé, il réécrirait le plist.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            LoginItem.migrateIfNeeded()
        }

        if CommandLine.arguments.contains("--test-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.report = ProcessMemory.report(limit: 3)
                print(
                    tr(
                        "bundle détecté : %@ — %@", "\(self.hasBundle)",
                        Bundle.main.bundleIdentifier ?? tr("aucun")))
                self.alertIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
        }

        if CommandLine.arguments.contains("--self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.selfTest() }
        }

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Rafraîchissement

    private func refresh() {
        snapshot = MemoryStats.read()
        let zone = snapshot.zone
        let cpu = cpuMonitor.sample()

        let dark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        statusItem.button?.image = Gauge.statusImage(
            score: snapshot.score, zone: zone, cpu: cpu?.total, dark: dark)
        let percent = Gauge.percent(snapshot.score)
        statusItem.button?.setAccessibilityValue(
            tr("Pression mémoire %lld %%, %@. Processeur : %@", percent, zone.label, cpuText()))
        statusItem.button?.toolTip = tr(
            "Pression mémoire : %lld %% — %@\nSwap : %@\nProcesseur : %@",
            percent, zone.label, formatBytes(snapshot.swapUsed), cpuText())

        checkDisk()

        if zone == .critical {
            if !wasCritical { alertIfNeeded() }
            wasCritical = true
        } else if snapshot.score < 0.72 {
            // hystérésis : on ne réarme qu'une fois clairement redescendu
            wasCritical = false
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        snapshot = MemoryStats.read()
        // Relevé frais à l'ouverture ; ignoré s'il date de moins d'une demi-seconde.
        cpuMonitor.sample()
        report = ProcessMemory.report(limit: 8, cpu: cpuMonitor.latest?.perProcess ?? [:])
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let zone = snapshot.zone
        let header = NSMenuItem()
        header.attributedTitle = headerText(zone: zone)
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        addInfo(tr("Apps"), formatBytes(snapshot.appMemory))
        addInfo(tr("Mémoire compressée"), formatBytes(snapshot.compressed))
        addInfo(tr("Réservée système"), formatBytes(snapshot.wired))
        addInfo(tr("Fichiers en cache"), tr("%@ (récupérable)", formatBytes(snapshot.cached)))
        addInfo(tr("Swap sur disque"), swapText())

        let disk = DiskCleanup.diskSpace()
        var diskText = tr("%@ libres", formatBytes(disk.free))
        if disk.isTight {
            diskText += tr("  ⚠︎ disque plein à %lld %%", Int(disk.usedRatio * 100))
        }
        addInfo(tr("Espace disque"), diskText)
        addInfo(tr("Processeur"), cpuText())

        menu.addItem(.separator())

        addSectionTitle(tr("Les plus gourmands en mémoire"))

        if report.entries.isEmpty {
            addPlaceholder(tr("Analyse en cours…"))
        }

        for usage in report.entries {
            menu.addItem(appItem(for: usage, measure: .memory))
        }

        if report.otherCount > 0 {
            menu.addItem(.separator())
            let detail = tr(
                count: report.otherCount, one: "1 processus · %@", other: "%lld processus · %@",
                formatBytes(report.otherTotal))
            addInfo(tr("Arrière-plan et système"), detail)
        }

        menu.addItem(.separator())

        addSectionTitle(tr("Les plus gourmands en processeur"))

        if let cpu = cpuMonitor.latest {
            if report.cpuEntries.isEmpty {
                addPlaceholder(tr("Aucun processus actif"))
            }
            for usage in report.cpuEntries {
                menu.addItem(appItem(for: usage, measure: .cpu))
            }
            // Ce qui manque à la liste pour atteindre le total : les processus root
            // (WindowServer, kernel_task, Spotlight…) illisibles sans privilège, les petits,
            // mais aussi un sixième processus actif coupé par la limite — d'où un libellé
            // neutre. Une estimation : le total et les processus ne sont pas relevés au
            // même instant.
            let listed = report.cpuEntries.reduce(0) { $0 + $1.cpu }
            let rest = cpu.total - listed
            if rest >= 0.01 {
                addInfo(tr("Autres processus et système"), "≈ " + formatShare(rest))
            }
        } else {
            addPlaceholder(tr("Mesure en cours…"))
        }

        menu.addItem(.separator())

        let cleanup = NSMenuItem(
            title: tr("Nettoyer les caches…"), action: #selector(showCleanup), keyEquivalent: "")
        cleanup.target = self
        menu.addItem(cleanup)

        let monitor = NSMenuItem(
            title: tr("Ouvrir le Moniteur d'activité"),
            action: #selector(openActivityMonitor), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)

        let login = NSMenuItem(
            title: tr("Lancer au démarrage"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(
            title: tr("Quitter Jauge RAM"), action: #selector(quitSelf), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func headerText(zone: Zone) -> NSAttributedString {
        let percent = Int((snapshot.score * 100).rounded())
        let text = NSMutableAttributedString(
            string: tr("Pression mémoire  %lld %%\n", percent),
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        text.append(
            NSAttributedString(
                string: zone.label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: Gauge.color(for: zone),
                ]))
        return text
    }

    private func swapText() -> String {
        if snapshot.swapUsed == 0 { return tr("aucun") }
        return formatBytes(snapshot.swapUsed)
    }

    private func cpuText() -> String {
        guard let cpu = cpuMonitor.latest else { return tr("mesure en cours…") }
        return tr("%@ sur %lld cœurs", formatShare(cpu.total), CPUMonitor.coreCount)
    }

    private func addSectionTitle(_ title: String) {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addPlaceholder(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfo(_ label: String, _ value: String) {
        let item = NSMenuItem()
        let text = NSMutableAttributedString(
            string: label + "  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        text.append(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]))
        item.attributedTitle = text
        item.isEnabled = false
        menu.addItem(item)
    }

    private enum Measure { case memory, cpu }

    private func appItem(for usage: AppUsage, measure: Measure) -> NSMenuItem {
        let item = NSMenuItem()

        let text = NSMutableAttributedString(
            string: usage.name + "  ",
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        var detail = measure == .memory ? formatBytes(usage.footprint) : formatShare(usage.cpu)
        if usage.processCount > 1 {
            detail += tr("  ·  %lld processus", usage.processCount)
        }
        text.append(
            NSAttributedString(
                string: detail,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        item.attributedTitle = text

        if let icon = usage.app?.icon {
            let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
            item.image = small
        }

        // Sous-menu : aucune action destructive au clic direct sur la ligne
        let submenu = NSMenu()

        if usage.isApp {
            let reveal = NSMenuItem(
                title: tr("Passer à l'app"), action: #selector(activateApp(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = usage
            submenu.addItem(reveal)

            submenu.addItem(.separator())

            let quit = NSMenuItem(
                title: tr("Quitter %@", usage.name), action: #selector(quitApp(_:)), keyEquivalent: "")
            quit.target = self
            quit.representedObject = usage
            submenu.addItem(quit)
        } else {
            let label = usage.isSystem
                ? tr("Composant système · pid %d", usage.id)
                : tr("Processus en arrière-plan · pid %d", usage.id)
            let info = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            info.isEnabled = false
            submenu.addItem(info)

            if usage.isSystem {
                let note = NSMenuItem(
                    title: tr("Géré par macOS — ne pas arrêter"), action: nil, keyEquivalent: "")
                note.isEnabled = false
                submenu.addItem(note)
            } else {
                submenu.addItem(.separator())
            }
        }

        if usage.isStoppable {
            let force = NSMenuItem(
                title: usage.isApp
                    ? tr("Forcer à quitter (travail non enregistré perdu)")
                    : tr("Arrêter le processus"),
                action: #selector(forceQuitApp(_:)), keyEquivalent: "")
            force.target = self
            force.representedObject = usage
            submenu.addItem(force)
        }

        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    @objc private func activateApp(_ sender: NSMenuItem) {
        guard let usage = sender.representedObject as? AppUsage else { return }
        usage.app?.activate(options: [.activateAllWindows])
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let usage = sender.representedObject as? AppUsage, let app = usage.app else { return }
        // terminate() est la demande polie : l'app peut proposer d'enregistrer.
        app.terminate()
    }

    @objc private func forceQuitApp(_ sender: NSMenuItem) {
        guard let usage = sender.representedObject as? AppUsage else { return }

        let alert = NSAlert()
        alert.messageText = tr("Forcer %@ à quitter ?", usage.name)
        alert.informativeText =
            usage.isApp
            ? tr("Tout travail non enregistré sera perdu.")
            : tr(
                "Ce processus sera arrêté immédiatement (pid %d). S'il fait partie du système "
                    + "ou d'un travail en cours, il peut y avoir des dégâts.", usage.id)
        alert.alertStyle = .warning
        alert.addButton(withTitle: usage.isApp ? tr("Forcer à quitter") : tr("Arrêter"))
        alert.addButton(withTitle: tr("Annuler"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let app = usage.app {
            app.forceTerminate()
        } else {
            // Le pid date de l'ouverture du menu : terminé entre-temps, il a pu être repris
            // par un autre processus. On vérifie avant chaque signal.
            guard ProcessMemory.isSameProcess(usage.id, startedAt: usage.startTime) else { return }
            // Demande polie d'abord, puis coupure franche si le processus s'accroche.
            kill(usage.id, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if ProcessMemory.isSameProcess(usage.id, startedAt: usage.startTime) {
                    kill(usage.id, SIGKILL)
                }
            }
        }
    }

    @objc private func showCleanup() {
        if cleanupWindow == nil {
            cleanupWindow = CleanupWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        cleanupWindow?.showWindow(nil)
        cleanupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func quitSelf() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerte

    private func requestNotificationPermission() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// UNUserNotificationCenter exige un bundle .app enregistré ; sinon il lève une exception.
    private var hasBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Le swap vit sur le disque : un disque saturé bloque la machine aussi sûrement
    /// qu'une RAM saturée, et sans prévenir.
    private func checkDisk() {
        let disk = DiskCleanup.diskSpace()
        guard disk.total > 0, disk.free < 10_000_000_000 || disk.usedRatio >= 0.95 else { return }
        if let last = lastDiskAlert, Date().timeIntervalSince(last) < 30 * 60 { return }
        lastDiskAlert = Date()

        notify(
            title: tr("Disque presque plein — %@ libres", formatBytes(disk.free)),
            body: tr("Le swap n'a plus de place. Ouvre « Nettoyer les caches… » dans la jauge."))
    }

    private func alertIfNeeded() {
        if let last = lastAlert, Date().timeIntervalSince(last) < alertCooldown { return }
        lastAlert = Date()

        let worst = report.entries.isEmpty ? ProcessMemory.report(limit: 3).entries : report.entries
        let names = worst.prefix(3).map { "\($0.name) (\(formatBytes($0.footprint)))" }
        let body =
            names.isEmpty
            ? tr("Ferme une application pour éviter que le Mac ne rame.")
            : tr("Les plus gourmandes : %@", names.joined(separator: ", "))

        notify(title: tr("Mémoire critique — %lld %%", Gauge.percent(snapshot.score)), body: body)
    }

    private func notify(title: String, body: String) {
        guard hasBundle else { return fallbackNotify(title: title, body: body) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                DispatchQueue.main.async { self.fallbackNotify(title: title, body: body) }
            }
        }
    }

    /// Construit réellement le menu et en imprime le contenu : vérifie d'un bloc
    /// la mesure, l'agrégation par app, le rendu et l'assemblage du menu.
    private func selfTest() {
        let frame = statusItem.button?.window?.frame ?? .zero
        print("status item  frame=\(frame) visible=\(statusItem.isVisible)")
        let none = tr("AUCUN")
        print("image        \(statusItem.button?.image?.size.debugDescription ?? none)")
        print(tr("libellé      %@", statusItem.button?.accessibilityLabel() ?? none))
        print(tr("valeur       %@", statusItem.button?.accessibilityValue() as? String ?? none))
        print("")
        menuWillOpen(menu)
        print(tr("menu : %lld éléments", menu.numberOfItems))
        for item in menu.items {
            let title = item.isSeparatorItem ? "──────────" : item.title.isEmpty
                ? item.attributedTitle?.string.replacingOccurrences(of: "\n", with: " / ") ?? "?"
                : item.title
            let flag = item.isEnabled ? " " : "·"
            print(" \(flag) \(title)")
            for sub in item.submenu?.items ?? [] {
                print("      ↳ \(sub.isSeparatorItem ? "──────" : sub.title)")
            }
        }
        exit(0)
    }

    private func fallbackNotify(title: String, body: String) {
        let escape: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }
}
