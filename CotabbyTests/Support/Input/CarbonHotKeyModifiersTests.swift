import Carbon.HIToolbox
import XCTest
@testable import Cotabby

@MainActor
final class CarbonHotKeyModifiersTests: XCTestCase {
    func test_eachModifierMapsToItsCarbonBit() {
        XCTAssertEqual(CarbonHotKeyModifiers.carbonFlags(for: .command), UInt32(cmdKey))
        XCTAssertEqual(CarbonHotKeyModifiers.carbonFlags(for: .shift), UInt32(shiftKey))
        XCTAssertEqual(CarbonHotKeyModifiers.carbonFlags(for: .option), UInt32(optionKey))
        XCTAssertEqual(CarbonHotKeyModifiers.carbonFlags(for: .control), UInt32(controlKey))
    }

    func test_combinedAndEmptyMasks() {
        XCTAssertEqual(CarbonHotKeyModifiers.carbonFlags(for: []), 0)
        XCTAssertEqual(
            CarbonHotKeyModifiers.carbonFlags(for: [.option, .shift]),
            UInt32(optionKey) | UInt32(shiftKey)
        )
    }

    func test_symbolsUseMenuOrder() {
        XCTAssertEqual(CarbonHotKeyModifiers.symbols(for: [.command, .option, .control, .shift]), "⌃⌥⇧⌘")
        XCTAssertEqual(CarbonHotKeyModifiers.symbols(for: .option), "⌥")
        XCTAssertEqual(CarbonHotKeyModifiers.symbols(for: []), "")
    }
}
