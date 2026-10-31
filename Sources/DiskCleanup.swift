import Foundation

/// Ce que l'on propose de nettoyer.
enum CacheKind {
    /// Caches d'outils de développement : entièrement reconstruits au besoin.
    case dev
    /// Caches système ou d'apps : sûrs à vider, mais une app ouverte peut broncher.
    case system
    /// Signalé pour information : gros, mais ce sont des données. Jamais supprimé ici.
    case data
}

struct CacheTarget {
    let name: String
    let detail: String
    /// Dossier dont on vide le contenu (le dossier lui-même est conservé).
    let path: String
    let kind: CacheKind

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    /// Le dossier, ou l'un de ses parents, est un lien symbolique : le vider viderait le
    /// dossier visé, qui peut être n'importe quoi. Jamais nettoyé.
    var isSymlinked: Bool { url.resolvingSymlinksInPath().path != url.standardizedFileURL.path }
    /// Coché d'avance uniquement pour ce qui est reconstruit sans perte.
    var checkedByDefault: Bool { kind == .dev && isRemovable }
    var isRemovable: Bool { kind != .data && !isSymlinked }
}

enum DiskCleanup {

    private static var home: String { NSHomeDirectory() }

    /// Liste fixe et explicite. Aucun parcours automatique : on ne supprime que des
    /// chemins connus, jamais un dossier découvert dynamiquement.
    static func allTargets() -> [CacheTarget] {
        let candidates = [
            CacheTarget(
                name: "Gradle", detail: tr("Dépendances et builds Android/Java"),
                path: home + "/.gradle/caches", kind: .dev),
            CacheTarget(
                name: "uv (Python)", detail: tr("Paquets Python téléchargés"),
                path: home + "/.cache/uv", kind: .dev),
            CacheTarget(
                name: "npm", detail: tr("Paquets Node téléchargés"),
                path: home + "/.npm/_cacache", kind: .dev),
            CacheTarget(
                name: "bun", detail: tr("Paquets installés par bun"),
                path: home + "/.bun/install/cache", kind: .dev),
            CacheTarget(
                name: "Hugging Face", detail: tr("Modèles téléchargés"),
                path: home + "/.cache/huggingface", kind: .dev),
            CacheTarget(
                name: "Puppeteer", detail: tr("Navigateurs téléchargés pour les tests"),
                path: home + "/.cache/puppeteer", kind: .dev),
            CacheTarget(
                name: "Cargo (Rust)", detail: tr("Registre et sources téléchargés"),
                path: home + "/.cargo/registry", kind: .dev),
            CacheTarget(
                name: "Xcode DerivedData", detail: tr("Builds intermédiaires, reconstruits"),
                path: home + "/Library/Developer/Xcode/DerivedData", kind: .dev),
            CacheTarget(
                name: tr("Caches d'applications"), detail: tr("~/Library/Caches — ferme tes apps avant"),
                path: home + "/Library/Caches", kind: .system),
            CacheTarget(
                name: tr("Simulateurs iOS"), detail: tr("Appareils et runtimes CoreSimulator"),
                path: home + "/Library/Developer/CoreSimulator/Caches", kind: .system),
            CacheTarget(
                name: "Parallels Desktop", detail: tr("Tes machines virtuelles — DONNÉES"),
                path: home + "/Library/Group Containers/4C6364ACXT.com.parallels.desktop.appstore",
                kind: .data),
            CacheTarget(
                name: tr("Téléchargements"), detail: tr("À trier toi-même"),
                path: home + "/Downloads", kind: .data),
        ]
        return candidates.filter(\.exists)
    }

    /// `du -sk` : bien plus rapide qu'un parcours FileManager sur des dizaines de Go.
    static func size(of target: CacheTarget) -> UInt64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", target.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8),
                let kb = UInt64(text.split(separator: "\t").first?.trimmingCharacters(
                    in: .whitespaces) ?? "")
            else { return 0 }
            return kb * 1024
        } catch {
            return 0
        }
    }

    /// Vide le contenu du dossier sans supprimer le dossier lui-même : certains outils
    /// s'attendent à le trouver et ne le recréent pas.
    @discardableResult
    static func clean(_ target: CacheTarget) -> (freed: UInt64, errors: [String]) {
        guard target.isRemovable else { return (0, [tr("%@ : protégé, non supprimé", target.name)]) }

        let before = size(of: target)
        // `du` peut prendre plusieurs secondes : on revérifie juste avant de supprimer.
        // Il reste une fenêtre minime, sans portée : qui peut écrire dans ce dossier peut
        // déjà tout supprimer lui-même.
        guard !target.isSymlinked else { return (0, [tr("%@ : lien symbolique, ignoré", target.name)]) }
        var errors: [String] = []
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
        for child in children {
            let path = (target.path as NSString).appendingPathComponent(child)
            do {
                try fm.removeItem(atPath: path)
            } catch {
                errors.append(tr("%@ : %@", child, error.localizedDescription))
            }
        }
        let after = size(of: target)
        return (before > after ? before - after : 0, errors)
    }

    // MARK: - Espace disque

    struct DiskSpace {
        var total: UInt64 = 0
        var free: UInt64 = 0
        var used: UInt64 { total > free ? total - free : 0 }
        var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Au-delà de 90 % d'occupation, APFS fragmente et le swap n'a plus de marge.
        var isTight: Bool { usedRatio >= 0.90 }
    }

    static func diskSpace() -> DiskSpace {
        var space = DiskSpace()
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
        else { return space }
        space.total = UInt64(values.volumeTotalCapacity ?? 0)
        space.free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return space
    }
}
