import AppKit
import WebTimeCore

@MainActor
private final class AllowanceProgressView: NSView {
  var fraction = 0.0 { didSet { needsDisplay = true } }
  var color = NSColor.systemBlue { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let trackRect = bounds.insetBy(dx: 0, dy: 1)
    NSColor.quaternaryLabelColor.setFill()
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
  private let onSnooze: @MainActor () -> Void
  private let faviconView = FaviconTileView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let stateView = NSImageView()
  private let progress = AllowanceProgressView()
  private lazy var snoozeButton = NSButton(
    title: "Snooze 15m", target: self, action: #selector(requestSnooze))

  override var allowsVibrancy: Bool { true }

  init(onSnooze: @escaping @MainActor () -> Void) {
    self.onSnooze = onSnooze
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
    faviconView.frame = NSRect(x: 14, y: 16, width: 23, height: 23)
    nameLabel.frame = NSRect(x: 47, y: 29, width: 193, height: 18)
    nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    detailLabel.frame = NSRect(x: 47, y: 14, width: 233, height: 15)
    detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    detailLabel.textColor = .secondaryLabelColor
    stateView.frame = NSRect(x: 267, y: 30, width: 12, height: 12)
    stateView.imageScaling = .scaleProportionallyUpOrDown
    snoozeButton.frame = NSRect(x: 199, y: 27, width: 82, height: 20)
    snoozeButton.bezelStyle = .rounded
    snoozeButton.controlSize = .mini
    snoozeButton.font = .systemFont(ofSize: 10, weight: .medium)
    snoozeButton.toolTip = "Allow this website for 15 minutes"
    snoozeButton.isHidden = true
    progress.frame = NSRect(x: 47, y: 5, width: 233, height: 5)
    [faviconView, nameLabel, detailLabel, stateView, snoozeButton, progress].forEach(addSubview)
  }

  required init?(coder: NSCoder) { nil }

  func update(
    name: String, favicon: NSImage?, used: TimeInterval, baseLimit: TimeInterval,
    additionalAllowance: TimeInterval, active: Bool, blocked: Bool, canSnooze: Bool
  ) {
    nameLabel.stringValue = name
    nameLabel.frame.size.width = canSnooze ? 145 : 193
    faviconView.image =
      favicon
      ?? NSImage(
        systemSymbolName: "globe", accessibilityDescription: "Website icon")
    faviconView.alphaValue = blocked ? 0.55 : 1
    let effectiveLimit = baseLimit + additionalAllowance
    let usedFraction = effectiveLimit > 0 ? min(1, used / effectiveLimit) : 1
    let remainingFraction = 1 - usedFraction
    let remaining = max(0, effectiveLimit - used)
    progress.fraction = remainingFraction
    progress.color =
      remainingFraction <= 0.1
      ? .systemRed : (remainingFraction <= 0.25 ? .systemOrange : .systemBlue)
    detailLabel.stringValue =
      additionalAllowance > 0
      ? "Snoozed · \(DurationText.compact(remaining)) left · \(DurationText.compact(effectiveLimit)) total"
      : "\(DurationText.compact(remaining)) left · \(Int(usedFraction * 100))% used · \(DurationText.compact(baseLimit)) set"
    snoozeButton.isHidden = !canSnooze
    if active && !blocked {
      stateView.image = NSImage(
        systemSymbolName: "play.fill", accessibilityDescription: "Active now")
      stateView.contentTintColor = .systemBlue
      stateView.toolTip = "Being counted now"
    } else {
      stateView.image = nil
      stateView.toolTip = blocked ? "Daily allowance exhausted" : nil
    }
  }

  @objc private func requestSnooze() {
    onSnooze()
  }
}
