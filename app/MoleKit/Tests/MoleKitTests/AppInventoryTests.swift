import XCTest
@testable import MoleKit

final class AppInventoryTests: XCTestCase {
    func testDecodeAppsArray() throws {
        let json = """
        [
          {"name": "Xcode", "bundle_id": "com.apple.dt.Xcode", "source": "App", "uninstall_name": "Xcode", "path": "/Applications/Xcode.app", "size": "12.4GB"},
          {"name": "Kitty", "bundle_id": "net.kovidgoyal.kitty", "source": "Homebrew", "uninstall_name": "kitty", "path": "/Applications/kitty.app", "size": "N/A"}
        ]
        """
        let apps = try AppInventoryClient.decode(Data(json.utf8))
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].bundleId, "com.apple.dt.Xcode")
        XCTAssertEqual(apps[0].sizeBytes, 12_400_000_000)
        XCTAssertEqual(apps[1].source, "Homebrew")
        XCTAssertEqual(apps[1].uninstallName, "kitty")
        XCTAssertNil(apps[1].sizeBytes)
    }

    func testDecodeRobotErrorSurfacesMessage() {
        let json = #"{"v":1,"event":"error","code":"E_INTERNAL","message":"apps list requires macOS","fatal":true}"#
        XCTAssertThrowsError(try AppInventoryClient.decode(Data(json.utf8))) { error in
            guard case let AppInventoryClient.InventoryError.robotError(message) = error else {
                return XCTFail("expected robotError, got \(error)")
            }
            XCTAssertEqual(message, "apps list requires macOS")
        }
    }

    func testDecodeGarbageIsMalformed() {
        XCTAssertThrowsError(try AppInventoryClient.decode(Data("not json".utf8)))
    }

    func testParseBytes() {
        XCTAssertEqual(InstalledApp.parseBytes("198.5MB"), 198_500_000)
        XCTAssertEqual(InstalledApp.parseBytes("1.2 GB"), 1_200_000_000)
        XCTAssertEqual(InstalledApp.parseBytes("512KB"), 512_000)
        XCTAssertNil(InstalledApp.parseBytes("N/A"))
        XCTAssertNil(InstalledApp.parseBytes(""))
    }
}
