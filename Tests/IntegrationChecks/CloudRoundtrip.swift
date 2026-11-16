import Foundation
import CryptoKit

@main struct CloudRoundtrip {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1])
        let cloudRoot = URL(fileURLWithPath: CommandLine.arguments[2])
        let folder = cloudRoot.appendingPathComponent("Cloud Transfer+ verification", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : folder.appendingPathComponent("roundtrip-" + UUID().uuidString + ".bin")
        guard url.standardizedFileURL.deletingLastPathComponent() == folder.standardizedFileURL,
              url.lastPathComponent.hasPrefix("roundtrip-") else { throw NSError(domain: "CloudCheck", code: 5, userInfo:[NSLocalizedDescriptionKey:"Only synthetic verification files are accepted"]) }
        let bytes = Data((0..<32768).map { UInt8($0 % 251) })
        if CommandLine.arguments.count > 3, try Data(contentsOf: url) != bytes { throw NSError(domain: "CloudCheck", code: 6, userInfo:[NSLocalizedDescriptionKey:"Existing file is not the synthetic test payload"]) }
        try bytes.write(to: workspace.appendingPathComponent("cloud-roundtrip-local-copy.bin"), options: .atomic)
        let original = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if CommandLine.arguments.count <= 3 { try bytes.write(to: url, options: .withoutOverwriting) }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,.ubiquitousItemIsUploadedKey,.ubiquitousItemIsUploadingKey,.ubiquitousItemUploadingErrorKey,.ubiquitousItemDownloadingErrorKey,.ubiquitousItemDownloadingStatusKey]
        var reportedError = false
        var uploaded = false
        for _ in 0..<120 {
            url.removeAllCachedResourceValues()
            let v = try url.resourceValues(forKeys: keys)
            if let error = v.ubiquitousItemUploadingError, !reportedError { print("Monitoring upload error: \(error.localizedDescription)"); reportedError = true }
            if v.isUbiquitousItem == true && v.ubiquitousItemIsUploaded == true && v.ubiquitousItemIsUploading != true { uploaded = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard uploaded else { throw NSError(domain: "CloudCheck", code: 1, userInfo:[NSLocalizedDescriptionKey:"Upload not confirmed within two minutes; test copies retained"]) }
        print("Synthetic test file: Apple reports uploaded")
        try fm.evictUbiquitousItem(at: url)
        var onlineOnly = false
        for _ in 0..<60 {
            url.removeAllCachedResourceValues()
            let v = try url.resourceValues(forKeys: keys)
            if v.ubiquitousItemDownloadingStatus == .notDownloaded { onlineOnly = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard onlineOnly else { throw NSError(domain: "CloudCheck", code: 2, userInfo:[NSLocalizedDescriptionKey:"Online-only status not confirmed; no remote-read-back claim made"]) }
        print("Synthetic test file: Apple reports online only")
        try fm.startDownloadingUbiquitousItem(at: url)
        var downloaded = false
        for _ in 0..<120 {
            url.removeAllCachedResourceValues()
            let v = try url.resourceValues(forKeys: keys)
            if let error = v.ubiquitousItemDownloadingError { throw error }
            if v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded { downloaded = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard downloaded else { throw NSError(domain: "CloudCheck", code: 3, userInfo:[NSLocalizedDescriptionKey:"Cloud retrieval not confirmed; local reference retained"]) }
        let returned = SHA256.hash(data: try Data(contentsOf:url)).map { String(format: "%02x", $0) }.joined()
        guard original == returned else { throw NSError(domain: "CloudCheck", code: 4, userInfo:[NSLocalizedDescriptionKey:"Retrieved checksum mismatch; test copies retained"]) }
        let report: [String:Any] = ["syntheticBytes":bytes.count,"appleReportedUploaded":uploaded,"appleReportedOnlineOnlyBeforeRetrieval":onlineOnly,"retrievalCompleted":downloaded,"retrievedSHA256Matched":original == returned,"testFile":url.path]
        try JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent("cloud-roundtrip-result.json"))
        print("PASS: 32 KB synthetic iCloud upload, eviction, retrieval and checksum comparison")
    }
}
