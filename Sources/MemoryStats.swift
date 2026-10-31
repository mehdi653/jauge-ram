import Foundation

/// Niveau de pression tel que le noyau le rapporte (kern.memorystatus_vm_pressure_level)
enum KernelPressure: Int32 {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0
}

enum Zone {
    case ok, warn, critical

    var label: String {
        switch self {
        case .ok: return tr("OK")
        case .warn: return tr("Ça chauffe")
        case .critical: return tr("Critique — ferme une app")
        }
    }
}

struct MemorySnapshot {
    var total: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var appMemory: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var kernel: KernelPressure = .unknown
    /// Score 0...1 affiché par la jauge
    var score: Double = 0

    var used: UInt64 { wired &+ compressed &+ appMemory }

    var zone: Zone {
        if score >= 0.80 { return .critical }
        if score >= 0.60 { return .warn }
        return .ok
    }
}

enum MemoryStats {

    private static let host = mach_host_self()

    private static var pageSize: UInt64 = {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            return UInt64(size)
        }
        return UInt64(vm_kernel_page_size)
    }()

    static func read() -> MemorySnapshot {
        var snap = MemorySnapshot()
        snap.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snap }

        let ps = pageSize
        let wired = UInt64(stats.wire_count) &* ps
        let compressed = UInt64(stats.compressor_page_count) &* ps
        let purgeable = UInt64(stats.purgeable_count) &* ps
        let internalPages = UInt64(stats.internal_page_count) &* ps
        let external = UInt64(stats.external_page_count) &* ps
        let speculative = UInt64(stats.speculative_count) &* ps
        let freePages = UInt64(stats.free_count) &* ps

        snap.wired = wired
        snap.compressed = compressed
        // « Mémoire des apps » au sens du Moniteur d'activité
        snap.appMemory = internalPages > purgeable ? internalPages - purgeable : 0
        // Fichiers en cache : récupérables à tout moment, ne comptent pas comme pression
        snap.cached = external &+ purgeable
        snap.free = freePages > speculative ? freePages - speculative : freePages

        snap.swapUsed = swapUsed()
        snap.kernel = kernelPressure()
        snap.score = score(for: snap)
        return snap
    }

    /// vm.swapusage → struct xsw_usage
    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func kernelPressure() -> KernelPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return KernelPressure(rawValue: level) ?? .unknown
    }

    /// Score composite.
    ///
    /// On n'utilise PAS « RAM utilisée / RAM totale » : macOS garde volontairement la RAM
    /// pleine de cache fichier, ce ratio est donc quasi toujours proche de 100 % et n'annonce rien.
    ///
    /// Trois signaux, du plus lent au plus grave :
    ///  1. (wired + compressé) / total — la part de RAM que le système ne peut pas libérer.
    ///  2. le swap effectivement écrit sur le SSD, rapporté à la RAM physique. Le total de swap
    ///     grandit dynamiquement sous macOS, donc « used / total » ne veut rien dire : on compare
    ///     à la RAM. La moitié de la RAM en swap = pénalité maximale.
    ///  3. le niveau annoncé par le noyau, qui impose un plancher et a toujours le dernier mot.
    private static func score(for snap: MemorySnapshot) -> Double {
        guard snap.total > 0 else { return 0 }
        let unreclaimable = Double(snap.wired &+ snap.compressed) / Double(snap.total)
        let swapPenalty = min(0.35, Double(snap.swapUsed) / Double(snap.total))

        var score = min(1.0, unreclaimable + swapPenalty)

        switch snap.kernel {
        case .warning: score = max(score, 0.70)
        case .critical: score = max(score, 0.92)
        case .normal, .unknown: break
        }
        return score
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let fmt = ByteCountFormatter()
    fmt.allowedUnits = [.useGB, .useMB]
    fmt.countStyle = .memory
    return fmt.string(fromByteCount: Int64(bytes))
}
