import AppKit
import Foundation

struct AppUsage {
    let id: Int32
    let name: String
    let footprint: UInt64
    /// Part du processeur, à l'échelle de la machine entière (voir CPUMonitor)
    let cpu: Double
    let processCount: Int
    /// Renseigné seulement pour les applications visibles : elles seules peuvent être
    /// quittées proprement (avec proposition d'enregistrer).
    let app: NSRunningApplication?
    /// Composant du système : affiché pour information, jamais proposé à l'arrêt.
    let isSystem: Bool
    /// Heure de démarrage du processus `id`, relevée avec la liste : vérifiée avant de lui
    /// envoyer un signal (voir ProcessMemory.isSameProcess).
    let startTime: UInt64?

    var isApp: Bool { app != nil }
    var isStoppable: Bool { isApp || !isSystem }
}

struct ProcessReport {
    var entries: [AppUsage] = []
    /// Les plus actifs sur le processeur, du plus au moins actif
    var cpuEntries: [AppUsage] = []
    var otherTotal: UInt64 = 0
    var otherCount: Int = 0
    /// Processus système que l'on ne peut pas mesurer sans privilège root
    var unreadableCount: Int = 0
}

enum ProcessMemory {

    /// Compteurs d'un processus (mémoire, temps processeur). Lisibles sans root pour les
    /// processus du même utilisateur.
    static func usage(of pid: Int32) -> rusage_info_v4? {
        var buf = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &buf) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
            }
        }
        return rc == 0 ? buf : nil
    }

    /// Un pid libéré peut être repris par un autre processus, en quelques secondes : avant
    /// un signal, l'heure de démarrage confirme qu'il désigne toujours celui de la liste.
    static func isSameProcess(_ pid: Int32, startedAt start: UInt64?) -> Bool {
        guard let start else { return false }
        return usage(of: pid)?.ri_proc_start_abstime == start
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    private static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Binaires livrés avec macOS : les arrêter va de l'inutile (ils redémarrent seuls)
    /// au risqué. On les montre, on ne propose pas de les tuer.
    private static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return true }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
    }

    /// pbi_comm est tronqué à 16 caractères ; le chemin complet donne un nom lisible.
    private static func name(of pid: Int32) -> String {
        if let path = path(of: pid) {
            return (path as NSString).lastPathComponent
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let comm = withUnsafePointer(to: info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            if !comm.isEmpty { return comm }
        }
        return "pid \(pid)"
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    /// Sous ce seuil, un processus ne pèse pas assez pour valoir une ligne de menu.
    private static let floor: UInt64 = 200 * 1024 * 1024

    /// Sous 1 % de la machine (12 % d'un cœur sur 12), un processus ne fait que respirer ;
    /// plus bas, la liste se remplit de petits workers système en plusieurs exemplaires.
    private static let cpuFloor = 0.01

    /// `cpu` : parts de processeur par pid, issues de CPUMonitor ; vide, pas de classement CPU.
    static func report(limit: Int = 8, cpu: [Int32: Double] = [:], cpuLimit: Int = 5) -> ProcessReport {
        var report = ProcessReport()

        // Applications visibles (celles qui ont une icône dans le Dock)
        var appByPid: [Int32: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier > 0 {
            appByPid[app.processIdentifier] = app
        }

        var parents: [Int32: Int32] = [:]
        var footprints: [Int32: UInt64] = [:]
        var starts: [Int32: UInt64] = [:]

        for pid in allPids() {
            guard let info = usage(of: pid) else {
                report.unreadableCount += 1
                continue
            }
            // Empreinte : l'équivalent de la colonne « Mémoire » du Moniteur d'activité.
            footprints[pid] = info.ri_phys_footprint
            starts[pid] = info.ri_proc_start_abstime
            parents[pid] = parent(of: pid)
        }

        // Chaque processus est rattaché à sa racine, en remontant la chaîne des parents.
        // C'est ce qui regroupe les ~40 helpers de Chrome sous Chrome, comme le fait le
        // Moniteur d'activité. Une app rencontrée en chemin l'emporte ; sinon on remonte
        // jusqu'au dernier ancêtre avant launchd.
        var totals: [Int32: UInt64] = [:]
        var cpuTotals: [Int32: Double] = [:]
        var counts: [Int32: Int] = [:]

        for (pid, size) in footprints {
            var cursor = pid
            var root = pid
            var hops = 0
            while hops < 24 {
                if appByPid[cursor] != nil { root = cursor; break }
                guard let up = parents[cursor], up > 1, up != cursor, footprints[up] != nil else {
                    root = cursor
                    break
                }
                cursor = up
                root = cursor
                hops += 1
            }
            totals[root, default: 0] &+= size
            cpuTotals[root, default: 0] += cpu[pid] ?? 0
            counts[root, default: 0] += 1
        }

        let ranked = totals.map { pid, size -> AppUsage in
            let app = appByPid[pid]
            return AppUsage(
                id: pid,
                name: app?.localizedName ?? name(of: pid),
                footprint: size,
                cpu: cpuTotals[pid] ?? 0,
                processCount: counts[pid] ?? 1,
                app: app,
                isSystem: app == nil && isSystemPath(path(of: pid)),
                startTime: starts[pid])
        }
        .sorted { $0.footprint > $1.footprint }

        // Le seuil ne doit jamais vider la liste : on montre toujours les premiers, même
        // modestes. En zone rouge, une piste faible vaut mieux qu'un menu vide.
        let alwaysShown = 5
        for entry in ranked {
            let room = report.entries.count < limit
            if room && (report.entries.count < alwaysShown || entry.footprint >= floor) {
                report.entries.append(entry)
            } else {
                report.otherTotal &+= entry.footprint
                report.otherCount += entry.processCount
            }
        }

        report.cpuEntries = Array(
            ranked.filter { $0.cpu >= cpuFloor }.sorted { $0.cpu > $1.cpu }.prefix(cpuLimit))
        return report
    }
}
