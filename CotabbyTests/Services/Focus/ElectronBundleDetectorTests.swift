import XCTest
@testable import Cotabby

@MainActor
final class ElectronBundleDetectorTests: XCTestCase {
    func test_detectsTheElectronFrameworkInsideTheBundle() {
        var checkedPaths: [String] = []
        let detector = ElectronBundleDetector { path in
            checkedPaths.append(path)
            return path == "/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework"
        }

        XCTAssertTrue(detector.isElectron(bundleURL: URL(fileURLWithPath: "/Applications/Claude.app")))
        XCTAssertFalse(detector.isElectron(bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        XCTAssertFalse(detector.isElectron(bundleURL: nil))
        XCTAssertEqual(checkedPaths.count, 2)
    }

    /// The focus poll asks every 50 ms; the file system is touched once per bundle.
    func test_cachesTheAnswerPerBundle() {
        var checks = 0
        let detector = ElectronBundleDetector { _ in
            checks += 1
            return true
        }
        let url = URL(fileURLWithPath: "/Applications/Slack.app")
        for _ in 0..<5 { _ = detector.isElectron(bundleURL: url) }
        XCTAssertEqual(checks, 1)
    }

    /// Real file-system check against a temporary fake bundle.
    func test_realFileSystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ElectronBundleDetectorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let electronApp = root.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(
            at: electronApp.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true
        )
        let nativeApp = root.appendingPathComponent("Native.app")
        try FileManager.default.createDirectory(at: nativeApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)

        let detector = ElectronBundleDetector()
        XCTAssertTrue(detector.isElectron(bundleURL: electronApp))
        XCTAssertFalse(detector.isElectron(bundleURL: nativeApp))
    }
}
