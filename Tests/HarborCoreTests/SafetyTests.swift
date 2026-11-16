import Foundation
import HarborCore

@MainActor final class SafetyTests {
    func entry(_ path: String, _ size: Int64 = 100, _ handle: String = "H:ABCDEFGH") -> ManifestEntry { .init(remoteHandle: handle, relativePath: path, expectedBytes: size) }

    func testTraversalAndAmbiguousPathsRejected() {
        for path in ["../escape", "/absolute", "a/../b", "a//b", "a/./b", "a\\b", "a\nb", "a:b", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try Safety.validate([entry(path)]), path)
        }
    }

    func testCaseAndUnicodeCollisionsRejected() {
        XCTAssertThrowsError(try Safety.validate([entry("A.txt"), entry("a.txt", 2, "H:IJKLMNOP")]))
        XCTAssertThrowsError(try Safety.validate([entry("é.txt"), entry("e\u{301}.txt", 2, "H:IJKLMNOP")]))
        XCTAssertThrowsError(try Safety.validate([entry("folder"), entry("folder/file", 2, "H:IJKLMNOP")]))
    }

    func testNoShellOrBadHandlesAndSizes() {
        XCTAssertThrowsError(try Safety.validate([.init(remoteHandle: "/folder", relativePath: "ok", expectedBytes: 1)]))
        XCTAssertThrowsError(try Safety.validate([entry("large", 25_000_000_001)]))
        XCTAssertThrowsError(try Safety.validate([entry("bad", -1)]))
    }

    func testSpaceIncludesReserveAndCopy() {
        // 50 GB reserve + 2 × 25 GB + 1 GB = 101 GB.
        XCTAssertFalse(Safety.hasRoom(available: 100_999_999_999, size: 25_000_000_000))
        XCTAssertTrue(Safety.hasRoom(available: 101_000_000_000, size: 25_000_000_000))
        XCTAssertFalse(Safety.hasRoom(available: 500_000_000_000, size: 25_000_000_001))
        XCTAssertTrue(Safety.downloadTimeout(for: 0) == 1_800)
        XCTAssertTrue(Safety.downloadTimeout(for: 25_000_000_000) == 1_800 + 100_000)
    }

    func testRunStagesThatBlockArchiving() {
        XCTAssertTrue(TransferStage.queued.isActive && TransferStage.awaitingUpload.isActive && TransferStage.downloaded.isActive)
        XCTAssertFalse(TransferStage.uploaded.isActive || TransferStage.released.isActive || TransferStage.needsReview.isActive || TransferStage.skipped.isActive)
    }

    func testValidManifest() throws { try Safety.validate([entry("Photos/holiday.jpg"), entry("Documents/report.pdf", 0, "H:IJKLMNOP"), entry("Films/big.mov", 25_000_000_000, "H:QRSTUVWX")]) }

    func testSymlinkEscapeRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try Safety.destination(root: root, relativePath: "escape/file"))
    }

    func testMegaListingParsing() throws {
        let listing = """
        FLAGS VERS SIZE DATE HANDLE NAME
        /Photos:
        d--- - - 1730000000 H:DIRABCDE Iceland
        ---- 1 0 1730000000 H:IJKLMNOP empty.txt
        ---- 1 30000000000 1730000000 H:QRSTUVWX huge.mov

        /Photos/Iceland:
        ---- 1 12345 1730000000 H:ABCDEFGH aurora 1.jpg
        """
        let result = try MegaListing.parse(listing, root: "/Photos")
        XCTAssertTrue(result.entries.count == 2)
        XCTAssertTrue(result.entries[0].relativePath == "Photos/empty.txt")
        XCTAssertTrue(result.entries[1] == ManifestEntry(remoteHandle: "H:ABCDEFGH", relativePath: "Photos/Iceland/aurora 1.jpg", expectedBytes: 12345))
        XCTAssertTrue(result.excluded.count == 1)
        XCTAssertThrowsError(try MegaListing.parse(listing + "\nunexpected continuation", root: "/Photos"))
        XCTAssertThrowsError(try MegaListing.parse("/Other:\n---- 1 10 1730000000 H:ABCDEFGH x.txt", root: "/Photos"))
        XCTAssertThrowsError(try MegaListing.parse("/Photos/a.pdf <H:ABCDEFGH> (14.62 MB)", root: "/Photos"))
        XCTAssertThrowsError(try MegaListing.parse("", root: "/Photos"))
        let first = try MegaListing.parse("/Photos/2024:\n---- 1 10 1730000000 H:ABCDEFGH IMG_0001.jpg", root: "/Photos/2024").entries[0]
        let second = try MegaListing.parse("/Photos/2025:\n---- 1 10 1730000000 H:IJKLMNOP IMG_0001.jpg", root: "/Photos/2025").entries[0]
        XCTAssertTrue(first.relativePath != second.relativePath)
        XCTAssertTrue(first.relativePath == "Photos/2024/IMG_0001.jpg")
        let node = try MegaMetadata.single("FLAGS VERS SIZE DATE HANDLE NAME\n---- 1 14623457 1730000000 H:ABCDEFGH name with spaces.pdf\n", handle: "H:ABCDEFGH")
        XCTAssertTrue(node.size == 14623457 && node.name == "name with spaces.pdf" && node.isFile)
        XCTAssertThrowsError(try MegaMetadata.single("---- 1 14.62 MB 1730000000 H:ABCDEFGH file", handle: "H:ABCDEFGH"))
        XCTAssertThrowsError(try MegaMetadata.single("---- 1 10 1730000000 H:IJKLMNOP file", handle: "H:ABCDEFGH"))
        XCTAssertThrowsError(try MegaMetadata.sourceRoot("/Photos/*"))
        XCTAssertThrowsError(try MegaMetadata.sourceRoot("/Photos/../Other"))
        XCTAssertTrue(try MegaMetadata.inventory("/Photos:\n---- 1 10 1730000000 H:ABCDEFGH \u{200E}photo.jpg", root: "/Photos").entries.count == 1)
        let folder = URL(fileURLWithPath: "/private/tmp/owned")
        let rows = try OwnedTransfers.parse("TAG|DESTINYPATH\n42|/private/tmp/owned/file|with-pipe.txt\n7|/private/tmp/owned-other/unrelated.txt\n")
        XCTAssertTrue(OwnedTransfers.owned(rows, by: folder).map(\.tag) == [42])
        XCTAssertThrowsError(try OwnedTransfers.parse("truncated transfer table"))
        XCTAssertThrowsError(try OwnedTransfers.parse("42|relative/file"))
    }

}

var checks = 0
@MainActor func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "") {
    checks += 1
    do { _ = try expression(); FileHandle.standardError.write(Data("Expected rejection failed: \(message)\n".utf8)); exit(1) } catch {}
}
@MainActor func XCTAssertFalse(_ expression: Bool) { checks += 1; precondition(!expression) }
@MainActor func XCTAssertTrue(_ expression: Bool) { checks += 1; precondition(expression) }

let suite = SafetyTests()
print("Testing unsafe paths"); suite.testTraversalAndAmbiguousPathsRejected()
print("Testing collisions"); suite.testCaseAndUnicodeCollisionsRejected()
print("Testing handles and sizes"); suite.testNoShellOrBadHandlesAndSizes()
print("Testing space rules"); suite.testSpaceIncludesReserveAndCopy()
suite.testRunStagesThatBlockArchiving()
try suite.testValidManifest()
print("Testing symlink escape"); try suite.testSymlinkEscapeRejected()
print("Testing MEGA listing parser"); try suite.testMegaListingParsing()
print("PASS: \(checks) safety assertions + valid manifest check")
