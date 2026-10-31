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
    print("RAM totale        \(formatBytes(snap.total))")
    print("Apps              \(formatBytes(snap.appMemory))")
    print("Compressée        \(formatBytes(snap.compressed))")
    print("Réservée système  \(formatBytes(snap.wired))")
    print("Cache fichiers    \(formatBytes(snap.cached))")
    print("Libre             \(formatBytes(snap.free))")
    print("Swap              \(formatBytes(snap.swapUsed))")
    print("Niveau noyau      \(snap.kernel)")
    print("SCORE             \(Int(snap.score * 100)) % — \(snap.zone.label)")
    if let cpu {
        print("Processeur        \(formatShare(cpu.total)) sur \(CPUMonitor.coreCount) cœurs"
            + " (utilisateur \(formatShare(cpu.user)), système \(formatShare(cpu.system)))")
    }
    print("")
    for entry in report.entries {
        let tag = entry.isApp ? "app " : "proc"
        let procs = entry.processCount > 1 ? "  (\(entry.processCount) proc)" : ""
        let name = entry.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  [\(tag)] \(name) \(formatBytes(entry.footprint))\(procs)")
    }
    print("  \(report.otherCount) autres processus : \(formatBytes(report.otherTotal))")
    print("  \(report.unreadableCount) processus système illisibles sans root")
    print("")
    print("Processeur, les plus actifs :")
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
        print("aperçu écrit : \(out)")
    }
    exit(0)
}

// Diagnostic disque : liste les cibles de nettoyage et leur taille, sans rien supprimer.
if CommandLine.arguments.contains("--disk") {
    let disk = DiskCleanup.diskSpace()
    print("Disque : \(formatBytes(disk.free)) libres sur \(formatBytes(disk.total)) "
        + "— occupé à \(Int(disk.usedRatio * 100)) %\(disk.isTight ? "  ⚠︎" : "")")
    print("")
    var reclaimable: UInt64 = 0
    for target in DiskCleanup.allTargets() {
        let size = DiskCleanup.size(of: target)
        let kind: String
        switch target.kind {
        case .dev: kind = "dev   "; if target.isRemovable { reclaimable += size }
        case .system: kind = "système"
        case .data: kind = "DONNÉES"
        }
        let mark = target.checkedByDefault ? "☑" : "☐"
        let name = target.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        let link = target.isSymlinked ? "  (lien symbolique, ignoré)" : ""
        print(" \(mark) [\(kind)] \(name) \(formatBytes(size))\(link)")
    }
    print("")
    print("Récupérable sans risque : \(formatBytes(reclaimable))")

    // Vérifie que la fenêtre se construit (contraintes Auto Layout comprises).
    let controller = CleanupWindowController()
    print("Fenêtre : \(controller.window != nil ? "construite" : "ÉCHEC")")
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
    FileHandle.standardError.write("Jauge RAM tourne déjà.\n".data(using: .utf8)!)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory : pas d'icône dans le Dock, uniquement la barre des menus
application.setActivationPolicy(.accessory)
application.run()
