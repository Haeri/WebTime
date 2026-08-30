import AppKit

@MainActor
private final class AllowanceProgressView: NSView {
  var fraction = 0.0 { didSet { needsDisplay = true } }
  var color = NSColor.systemGreen { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let trackRect = bounds.insetBy(dx: 0, dy: 1)
    NSColor.separatorColor.withAlphaComponent(0.72).setFill()
    NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()
    guard fraction > 0 else { return }
    let fillRect = NSRect(
      x: trackRect.minX, y: trackRect.minY, width: trackRect.width * min(1, fraction),
      height: trackRect.height)
    color.setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
  }
}

@MainActor
final class SiteProgressMenuView: NSView {
  private let faviconView = FaviconTileView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let stateView = NSImageView()
  private let progress = AllowanceProgressView()

  override var allowsVibrancy: Bool { true }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
    faviconView.frame = NSRect(x: 14, y: 16, width: 23, height: 23)
    nameLabel.frame = NSRect(x: 47, y: 29, width: 193, height: 18)
    nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    detailLabel.frame = NSRect(x: 47, y: 14, width: 233, height: 15)
    detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    detailLabel.textColor = .secondaryLabelColor
    stateView.frame = NSRect(x: 267, y: 30, width: 12, height: 12)
    stateView.imageScaling = .scaleProportionallyUpOrDown
    progress.frame = NSRect(x: 47, y: 5, width: 233, height: 5)
    [faviconView, nameLabel, detailLabel, stateView, progress].forEach(addSubview)
  }

  required init?(coder: NSCoder) { nil }

  func update(
    name: String, favicon: NSImage?, used: TimeInterval, limit: TimeInterval, active: Bool,
    blocked: Bool
  ) {
    nameLabel.stringValue = name
    faviconView.image =
      favicon
      ?? NSImage(
        systemSymbolName: "globe", accessibilityDescription: "Website icon")
    faviconView.alphaValue = blocked ? 0.55 : 1
    let usedFraction = limit > 0 ? min(1, used / limit) : 1
    let remainingFraction = 1 - usedFraction
    let remaining = max(0, limit - used)
    progress.fraction = remainingFraction
    progress.color =
      remainingFraction > 0.5
      ? .systemGreen : (remainingFraction > 0.1 ? .systemYellow : .systemRed)
    detailLabel.stringValue =
      "\(duration(remaining)) left · \(Int(usedFraction * 100))% used · \(duration(limit)) set"
    if blocked {
      stateView.image = NSImage(
        systemSymbolName: "lock.fill", accessibilityDescription: "Blocked")
      stateView.contentTintColor = .systemRed
      stateView.toolTip = "Daily allowance exhausted"
    } else if active {
      stateView.image = NSImage(
        systemSymbolName: "play.fill", accessibilityDescription: "Active now")
      stateView.contentTintColor = .systemGreen
      stateView.toolTip = "Being counted now"
    } else {
      stateView.image = NSImage(
        systemSymbolName: "pause.fill", accessibilityDescription: "Inactive")
      stateView.contentTintColor = .tertiaryLabelColor
      stateView.toolTip = "Not being counted"
    }
  }

  private func duration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds.rounded()) / 60)
    if totalMinutes >= 60 {
      let minutes = totalMinutes % 60
      return minutes == 0 ? "\(totalMinutes / 60)h" : "\(totalMinutes / 60)h \(minutes)m"
    }
    return "\(totalMinutes)m"
  }
}
