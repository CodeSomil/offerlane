import Foundation
import Network

/// Facts about this Mac that decide what can be installed and how well it will run.
public enum SystemCheck {
    public enum Chip: String, Sendable { case appleSilicon, intel }

    /// The real hardware, even when Offerlane itself runs under Rosetta.
    public static var chip: Chip {
        #if arch(arm64)
        return .appleSilicon
        #else
        return isTranslated ? .appleSilicon : .intel
        #endif
    }

    /// Offerlane is an Intel build running through Rosetta on Apple silicon ("Open using Rosetta" is ticked).
    public static var isTranslated: Bool {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    /// The platform name used by Claude Code's release manifest.
    public static var claudePlatform: String { chip == .appleSilicon ? "darwin-arm64" : "darwin-x64" }

    public static var ramBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Space macOS will make available for important downloads (includes purgeable space).
    public static func freeDiskBytes(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
    }

    /// Whether macOS has any usable network route. Answers within `timeout` seconds (assumes online if unsure).
    public static func isOnline(timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                if once.claim() { monitor.cancel(); c.resume(returning: path.status == .satisfied) }
            }
            monitor.start(queue: DispatchQueue(label: "offerlane.netcheck"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { monitor.cancel(); c.resume(returning: true) }
            }
        }
    }

    /// What this Mac has, in one value so provider setup can be tested with made-up machines.
    public struct Hardware: Sendable, Equatable {
        public var ramBytes: UInt64
        public var chip: Chip
        public var cores: Int
        public var freeDiskBytes: Int64
        public var macOSMajor: Int
        public init(ramBytes: UInt64, chip: Chip, cores: Int, freeDiskBytes: Int64, macOSMajor: Int) {
            self.ramBytes = ramBytes; self.chip = chip; self.cores = cores; self.freeDiskBytes = freeDiskBytes; self.macOSMajor = macOSMajor
        }
        /// 8 GB or less: local models get a smaller context and a smaller model.
        public var isLowMemory: Bool { ramBytes <= 8 << 30 }
    }

    /// Apple silicon GPUs share system RAM, so RAM and chip are what decide local model size.
    public static var hardware: Hardware {
        let p = ProcessInfo.processInfo
        return Hardware(ramBytes: ramBytes, chip: chip, cores: p.activeProcessorCount, freeDiskBytes: freeDiskBytes(),
                        macOSMajor: p.operatingSystemVersion.majorVersion)
    }

    public static func gb(_ bytes: Int64) -> String {
        let g = Double(bytes) / 1_000_000_000
        return g >= 10 ? "\(Int(g.rounded())) GB" : String(format: "%.1f GB", g)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
