import Foundation
import IOKit
import IOKit.ps

/// Reads battery, adapter and power telemetry.
///
/// Primary source (Apple Silicon): `AppleSmartBattery.PowerTelemetryData`.
/// Fallbacks: AppleSmartBattery voltage/current, AppleSMC (`PSTR`, `PDTR`,
/// `PPBR`) and IOPowerSources. The split between "computer supply" and
/// "battery charge" is calculated so that:
///
///     adapter input ≈ computer supply + battery charge
///
/// At 100% or during trickle charge the charging branch is intentionally zero.
final class PowerSampler: @unchecked Sendable {
    private let smc = SMCReader()
    private let isAppleSilicon: Bool

    init() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        isAppleSilicon = value == 1
    }

    func sample() -> PowerMetrics {
        let battery = BatteryRegistry.read()
        let powerSources = PowerSourceReader.read()
        let external = battery.externalConnected || powerSources.externalConnected

        let telemetry = battery.telemetry
        let smcPSTR = smc.readPlausibleWatts("PSTR")
        let smcPDTR = smc.readPlausibleWatts("PDTR")
        let smcBattery = smc.readPlausibleWatts("PPBR")

        let voltage = battery.voltageVolts
            ?? (smc.read("B0AV")?.number).map { $0 / 1000.0 }
            ?? powerSources.voltage
        let current = battery.amperageAmps

        let measuredBatteryWatts: Double? = {
            if let voltage, let current, voltage > 0, abs(current) > 0.01 {
                return abs(voltage * current)
            }
            if let batteryPower = telemetry["BatteryPower"], abs(batteryPower) > 20 {
                return abs(batteryPower) / 1000.0
            }
            if let smcBattery, smcBattery > 0.05 {
                return smcBattery
            }
            return nil
        }()

        var result = PowerMetrics.empty
        result.hasBattery = battery.hasBattery || powerSources.hasBattery
        result.source = external ? .alternatingCurrent : (result.hasBattery ? .battery : .unknown)
        result.batteryPercent = battery.percent ?? powerSources.percent ?? 0
        result.isCharging = battery.isCharging || powerSources.isCharging
        result.isFullyCharged = battery.fullyCharged
        result.cycleCount = battery.cycleCount
        result.temperatureCelsius = battery.temperatureCelsius
            ?? smc.read("TB0T").map { $0.number }
        result.batteryHealthPercent = battery.healthPercent
        result.voltageVolts = voltage
        result.amperageAmps = current
        result.adapterWatts = battery.adapterWatts ?? powerSources.adapterWatts
        result.timeRemainingMinutes = battery.timeRemainingMinutes
            ?? powerSources.timeToEmptyMinutes
        result.timeToFullMinutes = battery.timeToFullMinutes
            ?? powerSources.timeToFullMinutes

        if external {
            let inputFromTelemetry = telemetry["SystemPowerIn"].map { $0 / 1000.0 }
            let systemLoad = telemetry["SystemLoad"].map { $0 / 1000.0 }
            let input = validated(smcPDTR) ?? validated(inputFromTelemetry)
            let charging = result.isCharging ? validated(measuredBatteryWatts) : 0

            var supply: Double?
            if let input {
                if let charging, charging > 0.5 {
                    supply = max(0, input - charging)
                } else {
                    supply = input
                }
            } else if let systemLoad {
                supply = systemLoad
            } else if let smcPSTR {
                supply = smcPSTR
            }

            result.inputWatts = input ?? supply
            result.chargeWatts = charging
            result.supplyWatts = supply
            result.dischargeWatts = nil
            result.systemWatts = supply ?? systemLoad ?? smcPSTR

            if !result.isCharging {
                result.chargeWatts = 0
                result.supplyWatts = input ?? systemLoad ?? smcPSTR
                result.systemWatts = result.supplyWatts
            }
            let derivedCharge = (input != nil && supply != nil && result.isCharging)
            result.isSplitEstimated = result.isCharging && !(derivedCharge && measuredBatteryWatts != nil)

            var sources: [String] = []
            if !telemetry.isEmpty { sources.append("PowerTelemetry") }
            if smc.isAvailable, smcPDTR != nil || smcPSTR != nil { sources.append("SMC") }
            if sources.isEmpty { sources.append("IOPowerSources") }
            result.dataSource = (isAppleSilicon ? "Apple Silicon · " : "Intel · ") + sources.joined(separator: " · ")
        } else {
            let discharge = validated(measuredBatteryWatts)
                ?? validated(telemetry["BatteryPower"].map { abs($0) / 1000.0 })
                ?? validated(smcBattery)
            result.dischargeWatts = discharge
            result.systemWatts = discharge
            result.inputWatts = nil
            result.supplyWatts = nil
            result.chargeWatts = nil
            result.isSplitEstimated = discharge == nil
            result.dataSource = (isAppleSilicon ? "Apple Silicon · " : "Intel · ")
                + (discharge == nil ? "IOPowerSources" : "AppleSmartBattery")
        }

        if result.isFullyCharged {
            result.batteryPercent = max(result.batteryPercent, 99.5)
            if !result.isCharging {
                result.chargeWatts = 0
                if let input = result.inputWatts {
                    result.supplyWatts = input
                    result.systemWatts = input
                }
            }
        }

        return result
    }

    private func validated(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0.05, value < 500 else { return nil }
        return value
    }
}

// MARK: - AppleSmartBattery

private struct BatteryRegistry {
    var hasBattery = false
    var externalConnected = false
    var isCharging = false
    var fullyCharged = false
    var percent: Double?
    var healthPercent: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var voltageVolts: Double?
    var amperageAmps: Double?
    var timeRemainingMinutes: Int?
    var timeToFullMinutes: Int?
    var adapterWatts: Int?
    var telemetry: [String: Double] = [:]

    static func read() -> BatteryRegistry {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return BatteryRegistry() }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &propertiesRef,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return BatteryRegistry()
        }

        var result = BatteryRegistry()
        result.hasBattery = true
        result.externalConnected = bool(properties["ExternalConnected"])
        result.isCharging = bool(properties["IsCharging"])
        result.fullyCharged = bool(properties["FullyCharged"]) || bool(properties["BatteryData.FullyCharged"])

        let batteryData = dictionary(properties["BatteryData"])
        let rawCurrent = number(batteryData?["AppleRawCurrentCapacity"])
        let rawMax = number(batteryData?["AppleRawMaxCapacity"])
        let nominal = number(batteryData?["NominalChargeCapacity"])
        let design = number(batteryData?["DesignCapacity"])
        let currentPercent = number(properties["CurrentCapacity"])
        let maxPercent = number(properties["MaxCapacity"])

        if let rawCurrent, let rawMax, rawMax > 0 {
            result.percent = rawCurrent / rawMax * 100
        } else if let currentPercent, let maxPercent, maxPercent > 0 {
            result.percent = currentPercent / maxPercent * 100
        } else if let currentPercent {
            result.percent = currentPercent
        }

        if let nominal, let design, design > 0 {
            result.healthPercent = min(100, nominal / design * 100)
        } else if let rawMax, let design, design > 0 {
            result.healthPercent = min(100, rawMax / design * 100)
        }

        result.cycleCount = number(properties["CycleCount"]).map { Int($0) }

        if let temperature = number(properties["Temperature"]) {
            // AppleSmartBattery reports temperature in tenths of Kelvin.
            result.temperatureCelsius = temperature > 1_000
                ? temperature / 10 - 273.15
                : temperature
        }

        if let voltage = number(properties["Voltage"]), voltage > 100 {
            result.voltageVolts = voltage / 1000
        }

        if let amperage = number(properties["InstantAmperage"]), abs(amperage) > 0.01 {
            result.amperageAmps = amperage / 1000
        } else if let amperage = number(properties["Amperage"]) {
            result.amperageAmps = amperage / 1000
        }

        if let remaining = number(properties["AvgTimeToEmpty"]), remaining > 0, remaining < 65_535 {
            result.timeRemainingMinutes = Int(remaining)
        } else if let remaining = number(properties["TimeRemaining"]), remaining > 0, remaining < 65_535 {
            result.timeRemainingMinutes = Int(remaining)
        }

        if let toFull = number(properties["AvgTimeToFull"]), toFull > 0, toFull < 65_535 {
            result.timeToFullMinutes = Int(toFull)
        }

        if let adapter = dictionary(properties["AdapterDetails"]),
           let watts = number(adapter["Watts"]) {
            result.adapterWatts = Int(watts)
        }
        if result.adapterWatts == nil,
           let distribution = dictionary(properties["PowerDistribution"]),
           let milliwatts = number(distribution["IPDInputPower"]) {
            result.adapterWatts = Int((milliwatts / 1000).rounded())
        }

        if let telemetry = dictionary(properties["PowerTelemetryData"]) {
            for key in [
                "SystemPowerIn", "SystemLoad", "BatteryPower",
                "AdapterEfficiencyLoss", "SystemVoltageIn", "SystemCurrentIn"
            ] {
                if let value = number(telemetry[key]) {
                    result.telemetry[key] = value
                }
            }
        }

        return result
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        if let value = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, object) in value {
                if let key = key as? String { result[key] = object }
            }
            return result
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Double { return value }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "Yes" || value == "true" }
        return false
    }
}

// MARK: - IOPowerSources

private struct PowerSourceReader {
    var externalConnected = false
    var hasBattery = false
    var percent: Double?
    var isCharging = false
    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?
    var adapterWatts: Int?
    var voltage: Double?

    static func read() -> PowerSourceReader {
        var result = PowerSourceReader()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return result
        }

        for source in list {
            guard let descriptionRef = IOPSGetPowerSourceDescription(snapshot, source),
                  let description = descriptionRef.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            if let state = description[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSACPowerValue {
                    result.externalConnected = true
                }
                if description[kIOPSIsPresentKey] as? Bool == true {
                    result.hasBattery = true
                }
            }

            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int,
               max > 0 {
                result.percent = Double(current) / Double(max) * 100
            }
            if let charging = description[kIOPSIsChargingKey] as? Bool {
                result.isCharging = charging
            }
            if let empty = description[kIOPSTimeToEmptyKey] as? Int, empty > 0, empty < 65_535 {
                result.timeToEmptyMinutes = empty
            }
            if let full = description[kIOPSTimeToFullChargeKey] as? Int, full > 0, full < 65_535 {
                result.timeToFullMinutes = full
            }
            if let voltage = description["Voltage"] as? Double, voltage > 0 {
                result.voltage = voltage / 1000
            }
        }

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = adapter["Watts"] as? Int {
            result.adapterWatts = watts
        }

        return result
    }
}
