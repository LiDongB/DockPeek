import Foundation
import Darwin

/// Reads this process's own memory footprint via Mach, so the app can report exactly how much
/// resident memory it is using without needing any external tooling or permissions.
enum MemoryFootprint {

    /// Resident memory of the current process in bytes (`phys_footprint`, the number Activity
    /// Monitor reports as "Memory"), or `nil` when the kernel query fails.
    static func bytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Human readable footprint, e.g. "12.4 MB".
    static func formatted() -> String {
        guard let bytes = bytes() else { return "未知" }
        let megabytes = Double(bytes) / 1024 / 1024
        return String(format: "%.1f MB", megabytes)
    }
}
