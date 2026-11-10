import Foundation

@main
struct IndexScannerSmoke {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/test-temp", isDirectory: true)
            .appendingPathComponent("IndexScannerSmoke-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        for index in 0..<4 {
            try Data(repeating: 0x5A, count: 512 * 1024)
                .write(to: root.appendingPathComponent("file-\(index).bin"))
        }

        let scanner = IndexScanner(targets: [
            IndexScanner.Target(name: "Test Index", path: root.path, note: nil)
        ])
        let result = scanner.scan { _, _ in }
        precondition(result.categories.count == 1)
        precondition(result.categories[0].accessible)
        precondition(result.categories[0].bytes >= 2 * 1_048_576)
        precondition(result.totalBytes == result.categories[0].bytes)
        precondition(result.scannedFiles == 4)
        let sample = """
        -rw-r--r--  1 root  wheel  1024 Jan  1 00:00 segment-1
        drwxr-xr-x  2 root  wheel  4096 Jan  1 00:00 Cache
        -rw-r--r--+ 1 root  wheel  2048 Jan  1 00:00 segment-2
        """
        let parsed = IndexScanner.parseMdutilListing(sample)
        precondition(parsed?.bytes == 3072)
        precondition(parsed?.files == 2)
        precondition(IndexScanner.parseMdutilListing("") == nil)

        print("IndexScannerSmoke: PASS")
        print(" - bytes: \(result.totalBytes)")
        print(" - files: \(result.scannedFiles)")
        print(" - mdutil rows: \(parsed?.files ?? 0)")
    }
}
