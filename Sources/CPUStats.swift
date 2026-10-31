import Foundation

struct CPUSnapshot {
    /// Part de la capacité de la machine entière, 0...1 : 100 % = tous les cœurs occupés.
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    /// Même échelle que `total`, par pid
    var perProcess: [Int32: Double] = [:]
}

/// Utilisation du processeur.
///
/// Le noyau ne tient que des compteurs cumulés depuis le démarrage : un pourcentage
/// n'existe qu'entre deux relevés. `sample()` compare au relevé précédent ; la première
/// mesure n'est donc disponible qu'au deuxième appel.
///
/// Tout est rapporté à la machine entière, pour que la liste des processus s'additionne
/// au total affiché. Le Moniteur d'activité, lui, compte 100 % par cœur.
final class CPUMonitor {

    static let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// En deçà, l'écart entre deux relevés est trop court pour être fiable : on garde
    /// la mesure précédente sans déplacer la référence.
    private static let minimumInterval: UInt64 = 500_000_000

    private static let host = mach_host_self()

    /// ri_user_time et ri_system_time sont en unités mach et non en nanosecondes :
    /// sur Apple Silicon, une unité vaut 125/3 ns. Sans conversion, tout serait 42 fois trop bas.
    private static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    private struct ProcessTime {
        /// Heure de démarrage : distingue un pid réutilisé par un nouveau processus.
        let start: UInt64
        /// Temps cumulé utilisateur + système, en unités mach
        let ticks: UInt64
    }

    private var lastTicks: [UInt32]?
    private var lastTimes: [Int32: ProcessTime] = [:]
    private var lastUptime: UInt64 = 0

    /// Dernière mesure ; nil tant qu'il n'y a pas eu deux relevés.
    private(set) var latest: CPUSnapshot?

    @discardableResult
    func sample() -> CPUSnapshot? {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastTicks != nil, now &- lastUptime < Self.minimumInterval { return latest }
        guard let ticks = Self.hostTicks() else { return latest }
        let times = Self.processTimes()

        if let previous = lastTicks {
            // Compteurs 32 bits : la soustraction modulo absorbe un débordement.
            let delta = zip(ticks, previous).map { UInt64($0 &- $1) }
            let all = delta.reduce(0, +)
            var snap = CPUSnapshot()
            if all > 0 {
                let user = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]
                snap.user = Double(user) / Double(all)
                snap.system = Double(delta[Int(CPU_STATE_SYSTEM)]) / Double(all)
                snap.total = min(1, snap.user + snap.system)
            }
            let capacity = Double(now &- lastUptime) * Double(Self.coreCount)
            for (pid, time) in times {
                // Absent du relevé précédent : né entre-temps. Autre heure de démarrage :
                // le pid a été repris par un nouveau processus.
                guard let before = lastTimes[pid], before.start == time.start,
                    time.ticks > before.ticks
                else { continue }
                let nanoseconds = Double(time.ticks - before.ticks) * Self.nanosecondsPerTick
                snap.perProcess[pid] = min(1, nanoseconds / capacity)
            }
            latest = snap
        }

        lastTicks = ticks
        lastTimes = times
        lastUptime = now
        return latest
    }

    /// Ticks cumulés de tous les cœurs : utilisateur, système, inactif, nice.
    private static func hostTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    /// Temps processeur cumulé de chaque processus lisible.
    private static func processTimes() -> [Int32: ProcessTime] {
        var times: [Int32: ProcessTime] = [:]
        for pid in ProcessMemory.allPids() {
            guard let usage = ProcessMemory.usage(of: pid) else { continue }
            times[pid] = ProcessTime(
                start: usage.ri_proc_start_abstime,
                ticks: usage.ri_user_time &+ usage.ri_system_time)
        }
        return times
    }
}

/// Part de la machine en pourcentage : une décimale sous 10 %, où l'écart compte.
func formatShare(_ share: Double) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .percent
    fmt.maximumFractionDigits = share < 0.1 ? 1 : 0
    return fmt.string(from: NSNumber(value: share)) ?? "\(Int(share * 100)) %"
}
