import XCTest
@testable import Cotabby

/// Every branch of the "wake an unlisted Electron app only when the user is typing into it" rule.
@MainActor
final class ElectronAutoWakePolicyTests: XCTestCase {
    private func facts(
        bundleIdentifier: String? = "com.tinyspeck.slackmacgap",
        isElectron: Bool = true,
        isOnNamedAllowlist: Bool = false,
        isAlreadyHandled: Bool = false,
        secondsSinceLastKeyDown: Double = 0.4,
        isAutoWakeDisabled: Bool = false,
        excluded: Set<String> = []
    ) -> ElectronAutoWakePolicy.Facts {
        ElectronAutoWakePolicy.Facts(
            bundleIdentifier: bundleIdentifier,
            isElectron: isElectron,
            isOnNamedAllowlist: isOnNamedAllowlist,
            isAlreadyHandled: isAlreadyHandled,
            secondsSinceLastKeyDown: secondsSinceLastKeyDown,
            isAutoWakeDisabled: isAutoWakeDisabled,
            excludedBundleIdentifiers: excluded
        )
    }

    func test_wakesAnUnlistedElectronAppWhileTheUserTypes() {
        XCTAssertTrue(ElectronAutoWakePolicy.shouldWake(facts()))
        XCTAssertTrue(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: 3)))
    }

    /// Switching to an Electron app just to read must not wake it.
    func test_doesNotWakeWhenTheUserIsNotTyping() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: 3.01)))
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: .greatestFiniteMagnitude)))
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: .infinity)))
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: -1)))
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(secondsSinceLastKeyDown: .nan)))
    }

    func test_neverWakesNonElectronApps() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(bundleIdentifier: "com.apple.TextEdit", isElectron: false)))
    }

    /// Named-list apps and Chromium browsers are primed by the regular path; no double work.
    func test_leavesNamedAllowlistToTheRegularPath() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(isOnNamedAllowlist: true)))
    }

    func test_wakesEachProcessOnlyOnce() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(isAlreadyHandled: true)))
    }

    func test_globalKillSwitch() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(isAutoWakeDisabled: true)))
    }

    func test_excludedAppsAreNeverWoken_caseInsensitively() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(excluded: ["COM.tinyspeck.SlackMacGap"])))
        XCTAssertTrue(ElectronAutoWakePolicy.shouldWake(facts(excluded: ["com.spotify.client"])))
    }

    func test_missingBundleIdentifierIsNotWoken() {
        XCTAssertFalse(ElectronAutoWakePolicy.shouldWake(facts(bundleIdentifier: nil)))
    }
}
