import CoreGraphics

/// Bottom-left origin for the menu-bar panel, in AppKit screen coordinates (y grows upward).
/// The panel hangs below the menu bar with its left edge at the icon, so it extends right.
/// Without room on the right it flips so its right edge meets the icon's right edge,
/// and it is always kept inside `screen`, the screen's visible frame.
func panelOrigin(icon: CGRect, panel: CGSize, screen: CGRect) -> CGPoint {
    var x = icon.minX
    if x + panel.width > screen.maxX { x = icon.maxX - panel.width }
    x = min(max(x, screen.minX), screen.maxX - panel.width)
    let top = min(icon.minY, screen.maxY)
    return CGPoint(x: x, y: top - panel.height)
}
