import AppKit
import ImageIO
import SwiftUI

/// Downsampled first frames of preview images (gif/jpg/png), cached in memory.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL, maxPixel: Int = 480) async -> NSImage? {
        if let image = cached(url) { return image }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A 16:9 wallpaper preview: the cached still, or the animated original while `animating`. The image fills
/// a fixed-ratio box (its own size never affects layout).
struct PreviewImage: View {
    let url: URL?
    let placeholder: String
    var animating = false
    @State private var still: NSImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url, animating, url.pathExtension.lowercased() == "gif" {
                    AnimatedImage(url: url)
                } else if let still {
                    Image(nsImage: still).resizable().scaledToFill()
                } else {
                    Image(systemName: placeholder).font(.system(size: 28)).foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else { still = nil; return }
            still = Thumbnails.shared.cached(url)
            if still == nil { still = await Thumbnails.shared.load(url) }
        }
    }
}

/// NSImageView plays GIFs natively; scaled to fill and clipped by the parent.
private struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = FillImageView()
        view.animates = true
        view.imageScaling = .scaleAxesIndependently
        view.image = NSImage(contentsOf: url)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        context.coordinator.view = view
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view?.frame = FillImageView.fillFrame(image: context.coordinator.view?.image?.size,
                                                                   in: nsView.bounds)
        context.coordinator.view?.autoresizingMask = []
        nsView.postsFrameChangedNotifications = true
        context.coordinator.observe(nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: FillImageView?
        private var token: NSObjectProtocol?
        func observe(_ container: NSView) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container,
                                                           queue: .main) { [weak self, weak container] _ in
                MainActor.assumeIsolated {
                    guard let container, let view = self?.view else { return }
                    view.frame = FillImageView.fillFrame(image: view.image?.size, in: container.bounds)
                }
            }
        }
    }
}

/// Image view laid out "aspect fill" by its container (NSImageView itself only fits).
final class FillImageView: NSImageView {
    static func fillFrame(image: NSSize?, in bounds: NSRect) -> NSRect {
        guard let image, image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = max(bounds.width / image.width, bounds.height / image.height)
        let size = NSSize(width: image.width * scale, height: image.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}
