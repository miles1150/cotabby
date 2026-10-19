import AppKit
import XCTest
@testable import Cotabby

/// Guards around `primeAfterFocusFailure` that run before any Accessibility write. The test host
/// itself stands in for "the frontmost app": every case here must refuse to wake it, so no real
/// AX attribute is ever set from a test.
@MainActor
final class ElectronAutoWakeEnablerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ElectronAutoWakeEnablerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func enabler(isElectron: Bool, secondsSinceKey: Double) -> ChromiumAccessibilityEnabler {
        ChromiumAccessibilityEnabler(
            electronDetector: ElectronBundleDetector { _ in isElectron },
            defaults: defaults,
            secondsSinceLastKeyDown: { secondsSinceKey }
        )
    }

    func test_nonElectronAppIsNotWoken() {
        XCTAssertFalse(enabler(isElectron: false, secondsSinceKey: 0.1)
            .primeAfterFocusFailure(application: .current))
    }

    func test_electronAppIsNotWokenWhenTheUserIsNotTyping() {
        XCTAssertFalse(enabler(isElectron: true, secondsSinceKey: 60)
            .primeAfterFocusFailure(application: .current))
    }

    func test_killSwitchStopsAutoWake() {
        defaults.set(true, forKey: ElectronAutoWakePolicy.disabledDefaultsKey)
        XCTAssertFalse(enabler(isElectron: true, secondsSinceKey: 0.1)
            .primeAfterFocusFailure(application: .current))
    }

    func test_excludedAppIsNotWoken() throws {
        let bundleID = try XCTUnwrap(NSRunningApplication.current.bundleIdentifier)
        defaults.set([bundleID], forKey: ElectronAutoWakePolicy.excludedBundleIDsDefaultsKey)
        XCTAssertFalse(enabler(isElectron: true, secondsSinceKey: 0.1)
            .primeAfterFocusFailure(application: .current))
    }
}
