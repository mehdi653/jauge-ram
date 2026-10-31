import AppKit

// Mode diagnostic : `JaugeRAM --dump` imprime les mesures et quitte.
if CommandLine.arguments.contains("--dump") {
    let snap = MemoryStats.read()
    // Le processeur ne se mesure qu'entre deux relevés.
    let monitor = CPUMonitor()
    monitor.sample()
    Thread.sleep(forTimeInterval: 1)
    let cpu = monitor.sample()
    let report = ProcessMemory.report(limit: 10, cpu: cpu?.perProcess ?? [:])
    // Libellé traduit, complété à 18 caractères pour aligner les valeurs.
    func line(_ label: String, _ value: String) {
        print(label.padding(toLength: 18, withPad: " ", startingAt: 0) + value)
    }
    line(tr("RAM totale"), formatBytes(snap.total))
    line(tr("Apps"), formatBytes(snap.appMemory))
    line(tr("Compressée"), formatBytes(snap.compressed))
    line(tr("Réservée système"), formatBytes(snap.wired))
    line(tr("Cache fichiers"), formatBytes(snap.cached))
    line(tr("Libre"), formatBytes(snap.free))
    line(tr("Swap"), formatBytes(snap.swapUsed))
    line(tr("Niveau noyau"), "\(snap.kernel)")
    line(tr("SCORE"), tr("%lld %% — %@", Gauge.percent(snap.score), snap.zone.label))
    if let cpu {
        line(
            tr("Processeur"),
            tr(
                "%@ sur %lld cœurs (utilisateur %@, système %@)", formatShare(cpu.total),
                CPUMonitor.coreCount, formatShare(cpu.user), formatShare(cpu.system)))
    }
    print("")
    for entry in report.entries {
        let tag = entry.isApp ? "app " : "proc"
        let procs = entry.processCount > 1 ? "  (\(entry.processCount) proc)" : ""
        let name = entry.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  [\(tag)] \(name) \(formatBytes(entry.footprint))\(procs)")
    }
    print(
        tr(
            count: report.otherCount, one: "  1 autre processus : %@",
            other: "  %lld autres processus : %@", formatBytes(report.otherTotal)))
    print(
        tr(
            count: report.unreadableCount, one: "  1 processus système illisible sans root",
            other: "  %lld processus système illisibles sans root"))
    print("")
    print(tr("Processeur, les plus actifs :"))
    for entry in report.cpuEntries {
        let procs = entry.processCount > 1 ? "  (\(entry.processCount) proc)" : ""
        let name = entry.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  \(name) \(formatShare(entry.cpu))\(procs)")
    }
    exit(0)
}

// Aperçu : `JaugeRAM --preview chemin.png` rend la jauge à différents niveaux.
if let idx = CommandLine.arguments.firstIndex(of: "--preview"),
   idx + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[idx + 1]
    let samples: [(Double, Zone, Double)] = [
        (0.15, .ok, 0.03), (0.42, .ok, 0.12), (0.60, .warn, 0.08),
        (0.75, .warn, 0.35), (0.88, .critical, 0.61), (0.97, .critical, 0.94),
    ]
    let rowH: CGFloat = 34
    let size = NSSize(width: 290, height: rowH * CGFloat(samples.count) + 12)
    let canvas = NSImage(size: size)
    canvas.lockFocus()
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, sample) in samples.enumerated() {
        let y = size.height - CGFloat(i + 1) * rowH
        let item = Gauge.statusImage(score: sample.0, zone: sample.1, cpu: sample.2, dark: true)
        item.draw(in: NSRect(origin: NSPoint(x: 16, y: y + 6), size: item.size))
        let label = NSAttributedString(string: sample.1.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.lightGray])
        label.draw(at: NSPoint(x: 112, y: y + 10))
    }
    canvas.unlockFocus()
    if let tiff = canvas.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out))
        print(tr("aperçu écrit : %@", out))
    }
    exit(0)
}

// Diagnostic disque : liste les cibles de nettoyage et leur taille, sans rien supprimer.
if CommandLine.arguments.contains("--disk") {
    let disk = DiskCleanup.diskSpace()
    print(
        tr("Disque : %@ libres sur %@ — occupé à %lld %%", formatBytes(disk.free),
            formatBytes(disk.total), Int(disk.usedRatio * 100)) + (disk.isTight ? "  ⚠︎" : ""))
    print("")
    var reclaimable: UInt64 = 0
    for target in DiskCleanup.allTargets() {
        let size = DiskCleanup.size(of: target)
        let kind: String
        switch target.kind {
        case .dev: kind = "dev"; if target.isRemovable { reclaimable += size }
        case .system: kind = tr("système")
        case .data: kind = tr("DONNÉES")
        }
        let mark = target.checkedByDefault ? "☑" : "☐"
        let tag = kind.padding(toLength: 7, withPad: " ", startingAt: 0)
        let name = target.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        let link = target.isSymlinked ? tr("  (lien symbolique, ignoré)") : ""
        print(" \(mark) [\(tag)] \(name) \(formatBytes(size))\(link)")
    }
    print("")
    print(tr("Récupérable sans risque : %@", formatBytes(reclaimable)))

    // Vérifie que la fenêtre se construit (contraintes Auto Layout comprises).
    let controller = CleanupWindowController()
    print(controller.window != nil ? tr("Fenêtre : construite") : tr("Fenêtre : ÉCHEC"))
    exit(0)
}

// Instance unique. Sans ce verrou, lancer l'app alors que le LaunchAgent l'a déjà
// démarrée afficherait deux jauges côte à côte dans la barre des menus.
// Le descripteur reste ouvert pour toute la vie du processus : le verrou tombe à sa mort,
// y compris en cas de crash.
let diagnosticFlags = ["--self-test", "--test-alert"]
let isDiagnostic = CommandLine.arguments.contains { diagnosticFlags.contains($0) }

let lockPath = NSHomeDirectory() + "/Library/Caches/com.mehdi.jaugeram.lock"
let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
if !isDiagnostic, lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write((tr("Jauge RAM tourne déjà.") + "\n").data(using: .utf8)!)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory : pas d'icône dans le Dock, uniquement la barre des menus
application.setActivationPolicy(.accessory)
application.run()
