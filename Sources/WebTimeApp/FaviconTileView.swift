import AppKit

@MainActor
final class FaviconTileView: NSView {
  private let imageView = NSImageView()

  var image: NSImage? {
    get { imageView.image }
    set { imageView.image = newValue }
  }

  var contentTintColor: NSColor? {
    get { imageView.contentTintColor }
    set { imageView.contentTintColor = newValue }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    let inset = max(4, floor(min(bounds.width, bounds.height) * 0.18))
    imageView.frame = bounds.insetBy(dx: inset, dy: inset)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let tile = bounds.insetBy(dx: 0.5, dy: 0.5)
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(
      roundedRect: tile, xRadius: min(7, tile.width * 0.24),
      yRadius: min(7, tile.height * 0.24)
    ).fill()
    NSColor.black.withAlphaComponent(0.08).setStroke()
    let outline = NSBezierPath(
      roundedRect: tile, xRadius: min(7, tile.width * 0.24),
      yRadius: min(7, tile.height * 0.24))
    outline.lineWidth = 0.5
    outline.stroke()
  }
}
