import AppKit
import Darwin
import Foundation

enum MemoryPressureLevel: Int32, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0

    init(rawKernelValue: Int32) {
        switch rawKernelValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Normal"
        }
    }
}

struct SystemMemorySnapshot: Equatable {
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let pressure: MemoryPressureLevel

    var usedBytes: UInt64 {
        appBytes &+ wiredBytes &+ compressedBytes
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    var usedPercentInt: Int {
        Int((usedFraction * 100.0).rounded())
    }
}

struct ProcessMemoryItem {
    let pid: pid_t
    let pids: [pid_t]
    let name: String
    let footprintBytes: UInt64
    let executablePath: String?
    let bundleURL: URL?
    let processCount: Int
    let isGrouped: Bool
}

final class MemoryMonitor {
    private let totalRAM: UInt64
    private let pageSize: UInt64
    private var pidBuffer: [pid_t] = Array(repeating: 0, count: 1024)
    private var iconCache: [String: NSImage] = [:]
    private let maxIconCacheEntries = 64

    init() {
        var memSize: UInt64 = 0
        var sizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &sizeLen, nil, 0)
        self.totalRAM = memSize

        var pgSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pgSize)
        self.pageSize = UInt64(pgSize > 0 ? pgSize : 16384)
    }

    func sampleSystemMemory() -> SystemMemorySnapshot {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var appBytes: UInt64 = 0
        var wiredBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        var cachedBytes: UInt64 = 0
        var freeBytes: UInt64 = 0

        if kr == KERN_SUCCESS {
            let internalPages = UInt64(vmStats.internal_page_count)
            let purgeablePages = UInt64(vmStats.purgeable_count)
            let appPages = internalPages > purgeablePages ? (internalPages - purgeablePages) : 0

            appBytes = appPages &* pageSize
            wiredBytes = UInt64(vmStats.wire_count) &* pageSize
            compressedBytes = UInt64(vmStats.compressor_page_count) &* pageSize
            cachedBytes = (UInt64(vmStats.external_page_count) &+ purgeablePages) &* pageSize
            freeBytes = UInt64(vmStats.free_count) &* pageSize
        }

        var swap = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.stride
        let swapUsed: UInt64
        let swapTotal: UInt64
        if sysctlbyname("vm.swapusage", &swap, &swapLen, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        } else {
            swapUsed = 0
            swapTotal = 0
        }

        var pressureRaw: Int32 = 1
        var pressureLen = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureLen, nil, 0) != 0 {
            pressureRaw = 1
        }

        return SystemMemorySnapshot(
            totalBytes: totalRAM,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            freeBytes: freeBytes,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal,
            pressure: MemoryPressureLevel(rawKernelValue: pressureRaw)
        )
    }

    func sampleProcesses(limit: Int = 50, grouped: Bool = false, filter: String = "") -> [ProcessMemoryItem] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        let neededCapacity = Int(estimatedCount) + 64
        if pidBuffer.count < neededCapacity {
            pidBuffer = Array(repeating: 0, count: neededCapacity)
        }

        let bufferBytes = Int32(pidBuffer.count * MemoryLayout<pid_t>.stride)
        let actualCount = Int(proc_listallpids(&pidBuffer, bufferBytes))
        guard actualCount > 0 else { return [] }

        // Map running GUI applications once per scan for crisp app names & bundle URLs
        var runningApps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            runningApps[app.processIdentifier] = app
        }

        var rawItems: [ProcessMemoryItem] = []
        rawItems.reserveCapacity(min(actualCount, 256))

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var nameBuf = [CChar](repeating: 0, count: 128)

        for i in 0..<actualCount {
            let pid = pidBuffer[i]
            if pid <= 0 { continue }

            var ri = rusage_info_v4()
            let rusageResult = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rusageResult == 0 else { continue }

            let footprint = ri.ri_phys_footprint
            if footprint == 0 { continue }

            let runningApp = runningApps[pid]
            var execPath: String? = nil
            var bundleURL: URL? = runningApp?.bundleURL
            var displayName: String? = runningApp?.localizedName

            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if pathLen > 0 {
                let path = String(cString: pathBuf)
                execPath = path
                if displayName == nil {
                    displayName = URL(fileURLWithPath: path).lastPathComponent
                }
                if bundleURL == nil {
                    bundleURL = enclosingAppBundleURL(forExecutablePath: path)
                }
            }

            if displayName == nil || displayName?.isEmpty == true {
                let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                if nameLen > 0 {
                    displayName = String(cString: nameBuf)
                }
            }

            let resolvedName = displayName ?? "PID \(pid)"
            rawItems.append(
                ProcessMemoryItem(
                    pid: pid,
                    pids: [pid],
                    name: resolvedName,
                    footprintBytes: footprint,
                    executablePath: execPath,
                    bundleURL: bundleURL,
                    processCount: 1,
                    isGrouped: false
                )
            )
        }

        var result: [ProcessMemoryItem]
        if grouped {
            struct GroupAcc {
                var primaryPid: pid_t
                var hasRunningApp: Bool
                var pids: [pid_t]
                var name: String
                var bytes: UInt64
                var path: String?
                var bundle: URL?
            }
            var groups: [String: GroupAcc] = [:]
            groups.reserveCapacity(rawItems.count / 2)

            for item in rawItems {
                let key = groupKey(for: item)
                let isMainApp = runningApps[item.pid] != nil
                if var existing = groups[key] {
                    existing.bytes &+= item.footprintBytes
                    existing.pids.append(item.pid)
                    if isMainApp && !existing.hasRunningApp {
                        existing.primaryPid = item.pid
                        existing.hasRunningApp = true
                    }
                    if existing.bundle == nil, let b = item.bundleURL {
                        existing.bundle = b
                    }
                    groups[key] = existing
                } else {
                    let groupTitle = groupDisplayName(for: item)
                    groups[key] = GroupAcc(
                        primaryPid: item.pid,
                        hasRunningApp: isMainApp,
                        pids: [item.pid],
                        name: groupTitle,
                        bytes: item.footprintBytes,
                        path: item.executablePath,
                        bundle: item.bundleURL
                    )
                }
            }

            result = groups.values.map {
                ProcessMemoryItem(
                    pid: $0.primaryPid,
                    pids: $0.pids,
                    name: $0.name,
                    footprintBytes: $0.bytes,
                    executablePath: $0.path,
                    bundleURL: $0.bundle,
                    processCount: $0.pids.count,
                    isGrouped: $0.pids.count > 1
                )
            }
        } else {
            result = rawItems
        }

        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilter.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedFilter)
                    || String($0.pid).contains(trimmedFilter)
            }
        }

        result.sort { $0.footprintBytes > $1.footprintBytes }
        if result.count > limit {
            result.removeSubrange(limit..<result.count)
        }
        return result
    }

    func icon(for item: ProcessMemoryItem) -> NSImage {
        let cacheKey = item.bundleURL?.path ?? "__generic_daemon__"
        if let cached = iconCache[cacheKey] {
            return cached
        }

        let resolved: NSImage
        if let bundleURL = item.bundleURL {
            let img = NSWorkspace.shared.icon(forFile: bundleURL.path)
            img.size = NSSize(width: 16, height: 16)
            resolved = img
        } else {
            let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 16, height: 16))
            symbol.isTemplate = true
            resolved = symbol
        }

        if iconCache.count >= maxIconCacheEntries {
            iconCache.removeAll(keepingCapacity: true)
        }
        iconCache[cacheKey] = resolved
        return resolved
    }

    @discardableResult
    func terminateItem(_ item: ProcessMemoryItem, force: Bool) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if item.isGrouped {
            if let app = NSRunningApplication(processIdentifier: item.pid), item.pid != selfPID {
                return force ? app.forceTerminate() : app.terminate()
            }
            var anySucceeded = false
            for pid in item.pids where pid != selfPID {
                if terminateProcess(pid: pid, force: force) {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }
        guard item.pid != selfPID else { return false }
        return terminateProcess(pid: item.pid, force: force)
    }

    @discardableResult
    func terminateProcess(pid: pid_t, force: Bool) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    func clearTransientCaches() {
        if iconCache.count > 24 {
            iconCache.removeAll(keepingCapacity: false)
        }
    }

    private func enclosingAppBundleURL(forExecutablePath path: String) -> URL? {
        // Walk up to the outermost ".app" directory (skipping nested Helper.app when grouping or resolving icon)
        let components = (path as NSString).pathComponents
        for (idx, comp) in components.enumerated() where comp.hasSuffix(".app") {
            let sub = Array(components.prefix(idx + 1))
            return URL(fileURLWithPath: NSString.path(withComponents: sub))
        }
        return nil
    }

    private func groupKey(for item: ProcessMemoryItem) -> String {
        if let bundleURL = item.bundleURL {
            return bundleURL.path
        }
        return item.name
    }

    private func groupDisplayName(for item: ProcessMemoryItem) -> String {
        if let bundleURL = item.bundleURL {
            return bundleURL.deletingPathExtension().lastPathComponent
        }
        return item.name
    }
}

enum ByteFormatting {
    static func short(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 10.0 {
            return String(format: "%.1f GB", gb)
        } else if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 10.0 {
            return String(format: "%.0f MB", mb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.0f KB", max(1.0, kb))
    }

    static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.1fG", gb)
        }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1.0 {
            return String(format: "%.0fM", mb)
        }
        return "0M"
    }
}
