import CoreGraphics

/// File overview:
/// Pure geometry for the Explain & Translate panel. Given an anchor point (where the mouse was when
/// the user pressed the shortcut — usually the end of the selection they just dragged), the panel's
/// size, and the screen's visible frame, it returns where the panel should go.
///
/// All values are in AppKit screen coordinates (origin bottom-left, y grows upward), which is what
/// `NSEvent.mouseLocation`, `NSScreen.visibleFrame` and `NSWindow.setFrame` use. Accessibility
/// uses a top-left origin instead, so callers must never pass AX rectangles here unconverted.
nonisolated enum ExplainPanelLayout {
    /// Gap between the anchor and the panel so the panel does not cover the selected text's line.
    static let anchorGap: CGFloat = 14
    /// Minimum distance from the screen edges.
    static let edgeInset: CGFloat = 8

    static func frame(anchor: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        // Prefer below the anchor (the reading direction continues downward); flip above when the
        // panel would cross the bottom of the screen.
        var originY = anchor.y - anchorGap - size.height
        if originY < visibleFrame.minY + edgeInset {
            originY = anchor.y + anchorGap
        }
        // Start slightly left of the pointer so the panel visually hangs from it.
        var originX = anchor.x - 24

        // Clamp inside the visible frame on both axes.
        let maxX = visibleFrame.maxX - edgeInset - size.width
        let maxY = visibleFrame.maxY - edgeInset - size.height
        originX = min(max(originX, visibleFrame.minX + edgeInset), maxX)
        originY = min(max(originY, visibleFrame.minY + edgeInset), maxY)

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }
}
