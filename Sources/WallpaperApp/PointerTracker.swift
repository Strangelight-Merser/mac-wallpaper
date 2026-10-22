import AppKit

/// Desktop-level cursor tracking. The wallpaper windows ignore the mouse (clicks must reach Finder's
/// desktop), so scenes poll the cursor each frame and web pages get events from a global monitor
/// (no permission needed for mouse events). Input only counts while the cursor is over the desktop,
/// not over app windows, the Dock or the menu bar.
@MainActor
final class PointerTracker {
    private var cache: (point: NSPoint, overDesktop: Bool, time: CFTimeInterval)?

    /// Whether the topmost window at `point` (global, Cocoa coordinates) is desktop-level: our wallpaper
    /// windows or Finder's desktop icons. App windows are at layer ≥ 0, the Dock and menu bar above.
    func isOverDesktop(_ point: NSPoint) -> Bool {
        let now = CACurrentMediaTime()
        if let c = cache, c.point == point, now - c.time < 0.25 { return c.overDesktop }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        var over = number == 0
        if number > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
           let layer = info.first?[kCGWindowLayer as String] as? Int {
            over = layer < 0
        }
        cache = (point, over, now)
        return over
    }

    /// The cursor in `frame` as WE's pointer position (0…1, y down), if it is over the desktop there.
    func position(in frame: NSRect) -> SIMD2<Float>? {
        let m = NSEvent.mouseLocation
        guard frame.contains(m), isOverDesktop(m) else { return nil }
        return SIMD2(Float((m.x - frame.minX) / frame.width), Float((frame.maxY - m.y) / frame.height))
    }

    /// WE's `g_PointerState`: (left, right, press strength, 0).
    static var buttonState: SIMD4<Float> {
        let b = NSEvent.pressedMouseButtons
        let left: Float = b & 1 != 0 ? 1 : 0, right: Float = b & 2 != 0 ? 1 : 0
        return SIMD4(left, right, left, 0)
    }
}
