import AppKit
import MetalKit
import WERender

/// Borderless window pinned to the desktop level of one screen, below Finder's icons.
final class DesktopWindow: NSWindow {
    let screenID: CGDirectDisplayID
    let metalView: MTKView

    init(screen: NSScreen, device: MTLDevice) {
        screenID = screen.displayID
        metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = true
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true // started by the controller once the renderer is ready
        contentView = metalView
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
