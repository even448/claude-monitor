import Foundation

/// Scans macOS system index locations.
///
/// On macOS 26/27 `.Spotlight-V100` is protected beyond Full Disk Access:
/// `mdutil -L` itself requires root. The scanner therefore has two paths:
///  * direct enumeration for user/other index locations, and
///  * an explicit, user-triggered administrator read via `mdutil -L`.
///
/// The administrator password is handled entirely by macOS; the app never
/// receives or stores it.
final class IndexScanner: @unchecked Sendable {
    struct Target {
        let name: String
        let path: String
        let note: String?
    }

    static let spotlightPath = "/System/Volumes/Data/.Spotlight-V100"

    static let targets: [Target] = [
        Target(name: "Spotlight 索引", path: spotlightPath, note: "mds 索引正文与存储"),
        Target(name: "Spotlight 数据库", path: "/private/var/db/Spotlight", note: "系统级元数据数据库"),
        Target(name: "FSEvents 日志", path: "/System/Volumes/Data/.fseventsd", note: "文件事件历史"),
        Target(name: "文稿版本", path: "/System/Volumes/Data/.DocumentRevisions-V100", note: "自动保存版本"),
        Target(name: "用户 Spotlight", path: NSString(string: "~/Library/Metadata/CoreSpotlight").expandingTildeInPath, note: "当前用户的元数据索引")
    ]

    private let fileManager = FileManager.default
    private let targets: [Target]
    private let isModernMacOS: Bool

    init(targets: [Target] = IndexScanner.targets) {
        self.targets = targets
        let version = ProcessInfo.processInfo.operatingSystemVersion
        self.isModernMacOS = version.majorVersion >= 26
    }

    func scan(
        includeAdminSpotlight: Bool = false,
        progress: @escaping (Int, String) -> Void
    ) -> IndexScanResult {
        var categories: [IndexCategory] = []
        var total: Int64 = 0
        var totalFiles = 0
        var permissionLimited = false
        var spotlightNeedsAdmin = false
        var adminSpotlightUsed = false
        var adminError: String?

        for target in targets {
            var category: IndexCategory

            if target.path == Self.spotlightPath {
                category = directCategory(target, progress: progress)
                if !category.accessible, includeAdminSpotlight {
                    do {
                        let measurement = try measureSpotlightAsAdministrator()
                        category = IndexCategory(
                            name: target.name,
                            path: target.path,
                            bytes: measurement.bytes,
                            fileCount: measurement.files,
                            accessible: true,
                            note: "管理员读取 · mdutil -L（文件长度合计，不含 Cache）"
                        )
                        adminSpotlightUsed = true
                    } catch {
                        adminError = error.localizedDescription
                        if isModernMacOS { spotlightNeedsAdmin = true }
                    }
                } else if !category.accessible, isModernMacOS {
                    spotlightNeedsAdmin = true
                }
            } else {
                category = directCategory(target, progress: progress)
            }

            if !category.accessible {
                permissionLimited = true
                if target.path == Self.spotlightPath, isModernMacOS {
                    spotlightNeedsAdmin = true
                    if category.note?.contains("管理员") != true {
                        category = IndexCategory(
                            name: category.name,
                            path: category.path,
                            bytes: 0,
                            fileCount: 0,
                            accessible: false,
                            note: modernSpotlightNote
                        )
                    }
                }
            }

            categories.append(category)
            total &+= category.bytes
            totalFiles += category.fileCount
        }

        let errorMessage: String?
        if let adminError {
            errorMessage = adminError
        } else if permissionLimited {
            if spotlightNeedsAdmin && isModernMacOS {
                errorMessage = "Spotlight 索引受 macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) 系统保护，完全磁盘访问不足；可使用“管理员读取”。其他受限目录请检查完全磁盘访问。"
            } else {
                errorMessage = "部分系统索引目录不可读取，请在系统设置中授予完全磁盘访问权限。"
            }
        } else {
            errorMessage = nil
        }

        return IndexScanResult(
            totalBytes: total,
            categories: categories,
            scannedFiles: totalFiles,
            completedAt: Date(),
            permissionLimited: permissionLimited,
            errorMessage: errorMessage,
            adminSpotlightUsed: adminSpotlightUsed,
            spotlightNeedsAdmin: spotlightNeedsAdmin,
            adminErrorMessage: adminError
        )
    }

    // MARK: Direct enumeration

    private func directCategory(
        _ target: Target,
        progress: @escaping (Int, String) -> Void
    ) -> IndexCategory {
        guard fileManager.fileExists(atPath: target.path) else {
            return IndexCategory(
                name: target.name,
                path: target.path,
                bytes: 0,
                fileCount: 0,
                accessible: false,
                note: "目录不存在"
            )
        }

        // `isReadableFile`/access(2) is not TCC-aware and produces false
        // negatives for protected directories. A real top-level listing is a
        // better access probe.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: target.path)
        } catch {
            return IndexCategory(
                name: target.name,
                path: target.path,
                bytes: 0,
                fileCount: 0,
                accessible: false,
                note: noteForDeniedTarget(target)
            )
        }

        let url = URL(fileURLWithPath: target.path)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]

        var bytes: Int64 = 0
        var count = 0
        var hadError = false

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                hadError = true
                return true
            }
        ) else {
            return IndexCategory(
                name: target.name,
                path: target.path,
                bytes: 0,
                fileCount: 0,
                accessible: false,
                note: noteForDeniedTarget(target)
            )
        }

        for case let fileURL as URL in enumerator {
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { return }
                if values.isSymbolicLink == true { return }
                guard values.isRegularFile == true else { return }
                count += 1
                if count % 300 == 0 {
                    progress(count, fileURL.path)
                }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                bytes &+= max(0, size)
            }
        }

        if hadError && count == 0 {
            return IndexCategory(
                name: target.name,
                path: target.path,
                bytes: 0,
                fileCount: 0,
                accessible: false,
                note: noteForDeniedTarget(target)
            )
        }

        return IndexCategory(
            name: target.name,
            path: target.path,
            bytes: bytes,
            fileCount: count,
            accessible: true,
            note: hadError ? "部分内容不可读，可能受系统权限限制" : target.note
        )
    }

    // MARK: Administrator-assisted Spotlight read

    struct AdminMeasurement {
        let bytes: Int64
        let files: Int
    }

    private enum AdminReadError: LocalizedError {
        case cancelled
        case failed(String)
        case malformedOutput

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "已取消管理员读取；Spotlight 索引仍受 macOS 系统保护。"
            case .failed(let message):
                return "管理员读取失败：\(message)"
            case .malformedOutput:
                return "管理员读取返回了无法识别的 Spotlight 索引信息。"
            }
        }
    }

    private func measureSpotlightAsAdministrator() throws -> AdminMeasurement {
        // `mdutil -L` lists the Spotlight store and requires root. macOS asks
        // for the administrator password itself; the app never sees it.
        let shellCommand = "/usr/bin/mdutil -L /System/Volumes/Data"
        let script = "do shell script \"\(shellCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if stderrText.localizedCaseInsensitiveContains("cancel")
                || stderrText.localizedCaseInsensitiveContains("取消") {
                throw AdminReadError.cancelled
            }
            throw AdminReadError.failed(stderrText.isEmpty ? "osascript exited \(process.terminationStatus)" : stderrText)
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard let measurement = Self.parseMdutilListing(output) else {
            throw AdminReadError.malformedOutput
        }
        return measurement
    }

    /// `mdutil -L` emits `ls -l`-style rows. The fifth whitespace-separated
    /// field is the file length; only rows beginning with `-` are regular
    /// files. This intentionally sums file lengths, matching what macOS's own
    /// `mdutil -L | awk` examples do; it excludes the store's Cache folder.
    static func parseMdutilListing(_ output: String) -> AdminMeasurement? {
        var bytes: Int64 = 0
        var files = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("-") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, let size = Int64(fields[4]) else { continue }
            bytes &+= max(0, size)
            files += 1
        }
        guard files > 0 else { return nil }
        return AdminMeasurement(bytes: bytes, files: files)
    }

    // MARK: Notes

    private var modernSpotlightNote: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) 系统保护 · 需管理员读取"
    }

    private func noteForDeniedTarget(_ target: Target) -> String {
        if target.path == Self.spotlightPath, isModernMacOS {
            return modernSpotlightNote
        }
        if target.path.contains(".Spotlight") || target.path.contains(".fseventsd") {
            return "需要完全磁盘访问"
        }
        if target.path.contains(".DocumentRevisions") {
            return "系统保护目录 · 不可读"
        }
        return "目录不可读或不存在"
    }
}
