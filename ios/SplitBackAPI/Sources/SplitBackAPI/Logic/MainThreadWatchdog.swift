#if DEBUG
import Foundation
import Darwin

/// DEBUG-only main-thread hang detector: prints the main thread's backtrace (the frozen frames) when it
/// stalls. Start once from the main thread. Diagnostic only — remove after the hang is found.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()
    private let threshold: TimeInterval = 0.4
    private var mainThread: thread_t = mach_thread_self()
    private let lock = NSLock()
    private var lastPong = Date()
    private var started = false

    public func start() {
        guard Thread.isMainThread, !started else { return }
        started = true
        mainThread = mach_thread_self()                    // capture the MAIN thread's port
        Thread.detachNewThread { [self] in
            Thread.current.name = "main-thread-watchdog"
            while true {
                lock.lock(); let baseline = lastPong; lock.unlock()
                DispatchQueue.main.async { [self] in lock.lock(); lastPong = Date(); lock.unlock() }
                usleep(useconds_t(threshold * 1_000_000))
                lock.lock(); let now = lastPong; lock.unlock()
                if now == baseline {                       // main didn't pong → stalled
                    let frames = Self.backtrace(of: mainThread)
                    NSLog("⚠️ MAIN-THREAD HANG (>%.0fms)\n%@", threshold * 1000, frames.joined(separator: "\n"))
                    while true {                            // wait out the hang to avoid spam
                        usleep(200_000)
                        lock.lock(); let p = lastPong; lock.unlock()
                        if p != baseline { break }
                    }
                }
            }
        }
    }

    /// Breadcrumb with a timestamp — the last one before a hang localizes the freeze.
    public static func mark(_ label: @autoclosure () -> String) {
        NSLog("🔵 %.3f %@", Date().timeIntervalSince1970, label())
    }

    static func backtrace(of thread: thread_t) -> [String] {
        guard thread != mach_port_t(MACH_PORT_NULL), thread_suspend(thread) == KERN_SUCCESS
        else { return ["<suspend failed>"] }
        defer { thread_resume(thread) }
        var addrs: [UInt] = []
        var fp: UInt = 0
        #if arch(arm64)
        var s = arm_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &s) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(n)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &n) } }
        guard kr == KERN_SUCCESS else { return ["<get_state failed>"] }
        addrs.append(UInt(s.__pc)); addrs.append(UInt(s.__lr)); fp = UInt(s.__fp)
        #elseif arch(x86_64)
        var s = x86_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &s) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(n)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &n) } }
        guard kr == KERN_SUCCESS else { return ["<get_state failed>"] }
        addrs.append(UInt(s.__rip)); fp = UInt(s.__rbp)
        #endif
        var depth = 0
        while fp != 0, depth < 40, let frame = UnsafePointer<UInt>(bitPattern: fp) {
            let next = frame[0]; let ret = frame[1]
            if ret != 0 { addrs.append(ret) }
            if next <= fp { break }                         // stack grows down; fp must increase
            fp = next; depth += 1
        }
        return addrs.enumerated().map { symbolicate($0.element, index: $0.offset) }
    }

    private static func symbolicate(_ address: UInt, index: Int) -> String {
        for cand in [address, address & 0x0000_ffff_ffff_ffff] {   // 2nd strips arm64e PAC bits
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: cand), &info) != 0, let sn = info.dli_sname {
                let name = String(cString: sn)
                let mod = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let base = UInt(bitPattern: info.dli_saddr)
                return String(format: "%2d  %@  %@ + %lu", index, mod, name, cand >= base ? cand - base : 0)
            }
        }
        return String(format: "%2d  0x%016lx  <unknown>", index, address)
    }
}
#endif
