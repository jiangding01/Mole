import XCTest
@testable import MoleKit

final class DiagnosticsArchiverTests: XCTestCase {
    func testArchiveTemporaryDirectorySucceeds() async throws {
        let fileManager = FileManager.default
        let source = fileManager.temporaryDirectory
            .appendingPathComponent("DiagnosticsArchiverTests-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: source) }
        try "hello".write(to: source.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("DiagnosticsArchiverTests-out-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: destination) }

        let archiver = DiagnosticsArchiver()
        try await archiver.archive(sourceDirectory: source, destination: destination)

        XCTAssertTrue(fileManager.fileExists(atPath: destination.path))
    }

    func testArchiveMissingSourceThrows() async {
        let fileManager = FileManager.default
        let missingSource = fileManager.temporaryDirectory
            .appendingPathComponent("DiagnosticsArchiverTests-missing-\(UUID().uuidString)", isDirectory: true)
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("DiagnosticsArchiverTests-out-\(UUID().uuidString).zip")

        let archiver = DiagnosticsArchiver()
        do {
            try await archiver.archive(sourceDirectory: missingSource, destination: destination)
            XCTFail("expected sourceNotFound error")
        } catch let error as DiagnosticsArchiver.ArchiverError {
            XCTAssertEqual(error, .sourceNotFound)
        } catch {
            XCTFail("expected ArchiverError, got \(error)")
        }
    }
}
