import XCTest
@testable import Cotabby

/// Geometry tests in AppKit coordinates (origin bottom-left).
final class ExplainPanelLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 380, height: 220)

    func test_prefersBelowTheAnchor() {
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: 600, y: 600), size: size, visibleFrame: screen)
        XCTAssertEqual(frame.maxY, 600 - ExplainPanelLayout.anchorGap)
        XCTAssertEqual(frame.size, size)
    }

    func test_flipsAboveNearTheBottomEdge() {
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: 600, y: 100), size: size, visibleFrame: screen)
        XCTAssertEqual(frame.minY, 100 + ExplainPanelLayout.anchorGap)
    }

    func test_clampsToTheRightEdge() {
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: 1430, y: 600), size: size, visibleFrame: screen)
        XCTAssertEqual(frame.maxX, screen.maxX - ExplainPanelLayout.edgeInset)
    }

    func test_clampsToTheLeftEdge() {
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: 2, y: 600), size: size, visibleFrame: screen)
        XCTAssertEqual(frame.minX, screen.minX + ExplainPanelLayout.edgeInset)
    }

    /// A panel taller than the space above and below still stays fully on screen.
    func test_tallPanelStaysOnScreen() {
        let tall = CGSize(width: 380, height: 880)
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: 600, y: 450), size: tall, visibleFrame: screen)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + ExplainPanelLayout.edgeInset - 0.5)
        XCTAssertLessThanOrEqual(frame.minY, screen.maxY)
    }

    /// Secondary displays can sit at negative coordinates; clamping must use that screen's frame.
    func test_worksOnASecondaryScreenWithNegativeOrigin() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = ExplainPanelLayout.frame(anchor: CGPoint(x: -1000, y: 800), size: size, visibleFrame: left)
        XCTAssertTrue(left.contains(frame))
    }
}
