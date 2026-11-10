import Foundation
import IOKit

/// GPU utilisation is read from the public IORegistry property
/// `IOAccelerator.PerformanceStatistics["Device Utilization %"]`.
///
/// This works on both Apple Silicon and most Intel Macs without root. On
/// systems where the driver does not publish the property (or a future macOS
/// removes it), the UI shows an explicit unavailable state instead of guessing.
/// Metal performance counters would require additional entitlements/root and
/// are deliberately avoided.
final class GPUSampler: @unchecked Sendable {
    func sample() -> GPUMetrics {
        let classes = ["IOAccelerator", "IOGPU"]
        var best: GPUMetrics = .empty

        for className in classes {
            var iterator: io_iterator_t = 0
            guard let matching = IOServiceMatching(className),
                  IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                if let metrics = metrics(for: service) {
                    if (metrics.usage ?? -1) > (best.usage ?? -1) {
                        best = metrics
                    }
                }
            }
            if best.isAvailable { break }
        }

        return best
    }

    private func metrics(for service: io_object_t) -> GPUMetrics? {
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &propertiesRef,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let performance = (properties["PerformanceStatistics"] as? [String: Any])
            ?? (properties["PerformanceStatistics"] as? NSDictionary as? [String: Any])

        guard let performance else { return nil }

        let usage = number(performance["Device Utilization %"])
            ?? number(performance["Renderer Utilization %"])
            ?? number(performance["Tiler Utilization %"])

        guard let usage else { return nil }

        let memory = number(performance["In use system memory"])
            ?? number(performance["Alloc system memory"])
        let name = (properties["model"] as? String)
            ?? (properties["IOClass"] as? String)

        return GPUMetrics(
            usage: max(0, min(100, usage)),
            memoryBytes: memory.map { Int64($0) },
            name: name,
            isAvailable: true
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}
