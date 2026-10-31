import Foundation

/// Lancement au démarrage via un LaunchAgent utilisateur.
/// Choisi plutôt que SMAppService : celui-ci exige une app notarisée et enregistrée
/// auprès de LaunchServices, ce qu'une app signée localement (ad-hoc) n'est pas.
enum LoginItem {

    static let label = "com.mehdi.jaugeram"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    /// Ce que lance le LaunchAgent : `open` sur l'app, pas son exécutable.
    ///
    /// macOS 15 tue au lancement (« Launch Constraint Violation ») un binaire signé ad-hoc
    /// que launchd lance lui-même, dès qu'une recompilation a changé sa signature. Passée
    /// par LaunchServices, l'app démarre à chaque fois. `-g` : sans passer au premier plan.
    /// Hors d'un .app, rien : relancer l'exécutable direct reproduirait l'échec.
    private static var programArguments: [String]? {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { return nil }
        return ["/usr/bin/open", "-g", bundle]
    }

    /// Les versions précédentes lançaient l'exécutable directement : réécrit le plist s'il
    /// a encore cet ancien format et pointe vers cette app-ci. Une autre copie ouverte par
    /// mégarde ne détourne donc pas le lancement au démarrage. Pris en compte à la
    /// prochaine session ; rien n'est relancé.
    static func migrateIfNeeded() {
        guard isEnabled, let arguments = programArguments,
            let executable = Bundle.main.executablePath,
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            plist["ProgramArguments"] as? [String] == [executable]
        else { return }
        do {
            try write(arguments)
        } catch {
            NSLog("Jauge RAM : impossible de mettre à jour le lancement au démarrage — \(error)")
        }
    }

    private static func enable() {
        guard let arguments = programArguments else { return }
        do {
            try write(arguments)
            launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            NSLog("Jauge RAM : impossible d'activer le lancement au démarrage — \(error)")
        }
    }

    private static func write(_ arguments: [String]) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    private static func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }
}
