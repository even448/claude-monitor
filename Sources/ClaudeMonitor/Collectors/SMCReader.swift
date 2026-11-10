import Foundation
import IOKit

/// Minimal, read-only AppleSMC client.
///
/// AppleSMC exposes a fixed 80-byte YPC event structure through an IOKit user
/// client. The two selectors used here are `kSMCGetKeyInfo` (9) and
/// `kSMCReadKey` (5). This is the same mechanism used by long-standing open
/// source SMC tools. On Apple Silicon the service is `AppleSMCKeysEndpoint`;
/// IOKit matching by the `AppleSMC` class continues to work.
final class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private(set) var isAvailable = false

    init() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        if IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS {
            connection = conn
            isAvailable = true
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    struct Value {
        let number: Double
        let type: String
        let bytes: [UInt8]
    }

    func read(_ key: String) -> Value? {
        guard isAvailable, connection != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = 9 // kSMCGetKeyInfo

        var info = SMCKeyData()
        var infoSize = MemoryLayout<SMCKeyData>.stride
        var result = IOConnectCallStructMethod(
            connection,
            2, // kSMCHandleYPCEvent
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &info,
            &infoSize
        )
        guard result == KERN_SUCCESS, info.result == 0 else { return nil }

        let keyInfo = info.keyInfo
        guard keyInfo.dataSize > 0, keyInfo.dataSize <= 32 else { return nil }

        var readInput = SMCKeyData()
        readInput.key = input.key
        readInput.keyInfo = keyInfo
        readInput.data8 = 5 // kSMCReadKey

        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        result = IOConnectCallStructMethod(
            connection,
            2,
            &readInput,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }

        let bytes = output.byteArray
        let type = fourCCString(keyInfo.dataType)
        guard let number = decode(bytes: bytes, type: type) else { return nil }
        return Value(number: number, type: type, bytes: bytes)
    }

    func readPlausibleWatts(_ key: String) -> Double? {
        guard let value = read(key), value.number.isFinite, value.number > 0.01, value.number < 500 else {
            return nil
        }
        return value.number
    }

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func decode(bytes: [UInt8], type: String) -> Double? {
        guard !bytes.isEmpty else { return nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))

        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0

        case "sp87":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 128.0

        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 256.0

        case "ui8 ":
            return Double(bytes[0])

        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))

        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                (UInt32(bytes[0]) << 24)
                    | (UInt32(bytes[1]) << 16)
                    | (UInt32(bytes[2]) << 8)
                    | UInt32(bytes[3])
            )

        case "si8 ":
            return Double(Int8(bitPattern: bytes[0]))

        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])))

        case "si32":
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(Int32(bitPattern: raw))

        case "flag":
            return bytes[0] != 0 ? 1 : 0

        default:
            return nil
        }
    }
}

// MARK: - Exact 80-byte SMC event layout

private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCBytes32 {
    var values: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    var array: [UInt8] {
        withUnsafeBytes(of: values) { Array($0) }
    }
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimit = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes32()

    var byteArray: [UInt8] { bytes.array }
}
