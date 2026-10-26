import Darwin
import Foundation
import os

enum MemoryProbe {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func available() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}

final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private let thread: Thread

    init() {
        var sampler: PeakSampler?
        thread = Thread { sampler?.loop() }
        sampler = self
        peak = MemoryProbe.footprint()
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func loop() {
        while true {
            let value = MemoryProbe.footprint()
            lock.lock()
            peak = max(peak, value)
            let keepGoing = running
            lock.unlock()
            if !keepGoing { return }
            usleep(2_000)
        }
    }

    func stop() -> UInt64 {
        lock.lock()
        running = false
        peak = max(peak, MemoryProbe.footprint())
        let value = peak
        lock.unlock()
        return value
    }
}
