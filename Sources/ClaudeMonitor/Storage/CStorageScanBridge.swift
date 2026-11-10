import Foundation
import CStorageScanner

/// Thin Swift wrapper around the fts(3)-based scanner.
final class CStorageScanBridge: @unchecked Sendable {
    struct Output {
        var files: [String: StorageFileRecord] = [:]
        var directories: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        var scannedFiles: Int = 0
        var permissionLimited = false
        var errorMessage: String?
    }

    private final class ProgressBox {
        let handler: (Int, String) -> Void
        init(handler: @escaping (Int, String) -> Void) {
            self.handler = handler
        }
    }

    func scan(
        roots: [String],
        excludedPrefixes: [String],
        excludedNames: [String],
        minFileSize: Int64,
        minDirectorySize: Int64,
        progress: @escaping (Int, String) -> Void
    ) -> Output {
        guard !roots.isEmpty else { return Output() }

        let rootStrings = roots.map { strdup($0) }
        let prefixStrings = excludedPrefixes.map { strdup($0) }
        let nameStrings = excludedNames.map { strdup($0) }
        defer {
            rootStrings.forEach { free($0) }
            prefixStrings.forEach { free($0) }
            nameStrings.forEach { free($0) }
        }

        let rootPointers: [UnsafePointer<CChar>?] = rootStrings.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        let prefixPointers: [UnsafePointer<CChar>?] = prefixStrings.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        let namePointers: [UnsafePointer<CChar>?] = nameStrings.map { pointer in
            pointer.map { UnsafePointer($0) }
        }

        let box = ProgressBox(handler: progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        let callback: CMScanProgressCallback = { rawContext, scanned, path in
            guard let rawContext, let path else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(rawContext).takeUnretainedValue()
            box.handler(Int(scanned), String(cString: path))
        }

        let result: UnsafeMutablePointer<CMStorageScanResult>? = rootPointers.withUnsafeBufferPointer { rootBuffer in
            prefixPointers.withUnsafeBufferPointer { prefixBuffer in
                namePointers.withUnsafeBufferPointer { nameBuffer in
                    cm_storage_scan(
                        rootBuffer.baseAddress,
                        roots.count,
                        prefixBuffer.baseAddress,
                        excludedPrefixes.count,
                        nameBuffer.baseAddress,
                        excludedNames.count,
                        minFileSize,
                        minDirectorySize,
                        callback,
                        context
                    )
                }
            }
        }

        guard let result else {
            return Output(permissionLimited: true, errorMessage: "无法启动文件系统扫描")
        }
        defer { cm_storage_scan_result_free(result) }

        let raw = result.pointee
        var output = Output()
        output.totalBytes = raw.total_bytes
        output.scannedFiles = Int(raw.scanned_files)
        output.permissionLimited = raw.permission_limited != 0

        if let paths = raw.file_paths, let sizes = raw.file_sizes, let mtimes = raw.file_mtimes {
            for index in 0..<Int(raw.file_count) {
                guard let pathPointer = paths[index] else { continue }
                let path = String(cString: pathPointer)
                let mtime = mtimes[index]
                output.files[path] = StorageFileRecord(
                    size: sizes[index],
                    modifiedAt: Date(timeIntervalSince1970: mtime)
                )
            }
        }

        if let paths = raw.dir_paths, let sizes = raw.dir_sizes {
            for index in 0..<Int(raw.dir_count) {
                if let pathPointer = paths[index] {
                    output.directories[String(cString: pathPointer)] = sizes[index]
                }
            }
        }

        if let error = raw.error_message {
            output.errorMessage = String(cString: error)
            output.permissionLimited = true
        }

        return output
    }
}
