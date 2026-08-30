import AppKit
import Darwin
import Foundation
import WebTimeCore

private enum SingleInstanceLockError: Error {
  case alreadyRunning
  case unavailable(Int32)
}

private final class SingleInstanceLock {
  private let fileDescriptor: Int32

  init() throws {
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "local.web-time.app-\(getuid()).lock")
    let descriptor = Darwin.open(
      lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw SingleInstanceLockError.unavailable(errno) }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      Darwin.close(descriptor)
      if lockError == EWOULDBLOCK { throw SingleInstanceLockError.alreadyRunning }
      throw SingleInstanceLockError.unavailable(lockError)
    }

    fileDescriptor = descriptor
  }

  deinit {
    flock(fileDescriptor, LOCK_UN)
    Darwin.close(fileDescriptor)
  }
}

@MainActor
private final class ControlsStatusMenuView: NSView {
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 24))

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = .tertiaryLabelColor
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingTail

    let row = NSStackView(views: [iconView, titleLabel])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 9),
      iconView.heightAnchor.constraint(equalToConstant: 9),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func update(title: String, symbol: String) {
    titleLabel.stringValue = title
    let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
    iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
      .withSymbolConfiguration(configuration)
  }
}

@MainActor
private final class ManualEntryTextField: NSTextField {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "v"
    {
      NSSound.beep()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? { nil }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private static let maximumMenuSites = 5

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let daemon = DaemonClient()
  private let detector = NetworkActivityDetector()
  private let faviconLoader = FaviconLoader()
  private var store: JSONStore!
  private var configuration = LimiterConfiguration()
  private var ledger = UsageLedger()
  private var history = UsageHistory()
  private var timer: Timer?
  private var interactionMonitor: Any?
  private var sampleInFlight = false
  private var policySyncInFlight = false
  private var activeSiteIDs = Set<String>()
  private var daemonOnline = false
  private var lastPolicies: [DaemonSitePolicy]?
  private var controlsSession = ControlsSession()
  private var settingsController: SiteSettingsWindowController?
  private var statisticsController: StatisticsWindowController?
  private var menuRebuildScheduled = false
  private var menuRebuildDeferredForSettings = false
  private var menuIsOpen = false
  private var menuRankingChangedWhileOpen = false
  private var displayedMenuSiteIDs: [String] = []
  private lazy var idleStatusImage = webTimeImage()

  private var siteViews: [String: SiteProgressMenuView] = [:]
  private let controlsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let controlsStatusView = ControlsStatusMenuView()
  private let lockActionItem = NSMenuItem(
    title: "Unlock controls…", action: #selector(toggleControlsLock), keyEquivalent: "")
  private let manageItem = NSMenuItem(
    title: "Manage websites…", action: #selector(manageWebsites), keyEquivalent: ",")
  private let statisticsItem = NSMenuItem(
    title: "Statistics…", action: #selector(showStatistics), keyEquivalent: "s")
  private let quitItem = NSMenuItem(
    title: "Quit Web Time", action: #selector(quitApplication), keyEquivalent: "q")

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    do {
      store = JSONStore(directory: try AppPaths.supportDirectory())
    } catch {
      NSApp.presentError(error)
      return
    }
    configuration =
      store.load(LimiterConfiguration.self, from: "configuration.json") ?? LimiterConfiguration()
    configuration.sites = configuration.sites.map { site in
      var updated = site
      updated.domains = SiteDomains.expandedKnownDomains(site.domains)
      return updated
    }
    ledger = UsageLedger(usage: store.load(DailyUsage.self, from: "usage.json"))
    history = store.load(UsageHistory.self, from: "history.json") ?? UsageHistory()
    buildMenu()
    interactionMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      ]) { [weak self] event in
        MainActor.assumeIsolated { self?.touchControls() }
        return event
      }
    update(now: Date())
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.update(now: Date()) }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
    persist()
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuIsOpen = true
    if controlsAreUnlocked(at: Date()) { touchControls() }
    refreshDisplay(now: Date())
  }

  func menuDidClose(_ menu: NSMenu) {
    menuIsOpen = false
    guard menuRankingChangedWhileOpen else { return }
    menuRankingChangedWhileOpen = false
    scheduleMenuRebuild()
  }

  private var rankedMenuSites: [SiteConfiguration] {
    SiteRanking.mostUsed(
      configuration.sites,
      consumedBySite: ledger.usage.consumedBySite,
      limit: Self.maximumMenuSites)
  }

  private func buildMenu() {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    statusItem.button?.imagePosition = .imageOnly
    siteViews.removeAll()
    let menuSites = rankedMenuSites
    displayedMenuSiteIDs = menuSites.map(\.id)
    for site in menuSites {
      let item = NSMenuItem()
      let view = SiteProgressMenuView()
      item.view = view
      siteViews[site.id] = view
      menu.addItem(item)
    }
    if configuration.sites.isEmpty {
      menu.addItem(NSMenuItem(title: "No websites configured", action: nil, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    statisticsItem.target = self
    menu.addItem(statisticsItem)
    menu.addItem(.separator())
    controlsItem.view = controlsStatusView
    controlsItem.isEnabled = false
    menu.addItem(controlsItem)
    lockActionItem.target = self
    manageItem.target = self
    quitItem.target = self
    menu.addItem(lockActionItem)
    menu.addItem(manageItem)
    menu.addItem(quitItem)
    statusItem.menu = menu
    refreshDisplay(now: Date())
  }

  private func update(now: Date) {
    archiveAndResetIfNeeded(at: now)
    let increments = ledger.tick(at: now, activeSiteIDs: activeSiteIDs, limits: limitsBySite)
    history.record(totals: ledger.usage.consumedBySite, increments: increments, at: now)
    history.trim(keepingRecentDays: 400)
    if controlsSession.unlockedUntil != nil && !controlsAreUnlocked(at: now) { lockControls() }
    persist()
    refreshDisplay(now: now)
    refreshMenuRankingIfNeeded()
    refreshStatistics()
    guard !sampleInFlight else { return }
    sampleInFlight = true
    let detector = detector
    let daemon = daemon
    let grace = configuration.idleGraceSeconds
    let foregroundHints = foregroundProcessHints()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let status = try? daemon.send(.status)
      let active =
        status.map {
          detector.sample(
            addressesBySite: $0.learnedAddressesBySite, idleGrace: grace,
            foregroundProcessHints: foregroundHints, now: now)
        } ?? []
      DispatchQueue.main.async {
        guard let self else { return }
        self.sampleInFlight = false
        self.activeSiteIDs = active
        self.daemonOnline = status?.ok == true
        self.syncPoliciesIfNeeded()
        self.refreshDisplay(now: Date())
      }
    }
  }

  private var limitsBySite: [String: TimeInterval] {
    configuration.sites.reduce(into: [:]) { result, site in
      result[site.id] = site.dailyLimitSeconds
    }
  }

  private func policies(allAllowed: Bool = false) -> [DaemonSitePolicy] {
    configuration.sites.map { site in
      DaemonSitePolicy(
        id: site.id, domains: site.domains,
        blocked: allAllowed
          ? false : ledger.shouldBlock(siteID: site.id, limit: site.dailyLimitSeconds))
    }
  }

  private func syncPoliciesIfNeeded() {
    let desired = policies()
    guard daemonOnline, !policySyncInFlight, desired != lastPolicies else { return }
    policySyncInFlight = true
    let daemon = daemon
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = try? daemon.send(.updatePolicies(desired))
      DispatchQueue.main.async {
        guard let self else { return }
        self.policySyncInFlight = false
        if result?.ok == true { self.lastPolicies = desired } else { self.daemonOnline = false }
        self.refreshDisplay(now: Date())
      }
    }
  }

  private func archiveAndResetIfNeeded(at date: Date) {
    let today = UsageLedger.dayKey(for: date)
    if ledger.usage.day != today {
      history.days[ledger.usage.day] = ledger.usage.consumedBySite
      ledger.resetIfNeeded(at: date)
      lastPolicies = nil
    }
  }

  private func refreshDisplay(now: Date) {
    let unlocked = controlsAreUnlocked(at: now)
    let displayedSite = configuration.sites.first(where: { activeSiteIDs.contains($0.id) })
    if let site = displayedSite {
      let used = ledger.consumed(siteID: site.id)
      let usedFraction = site.dailyLimitSeconds > 0 ? min(1, used / site.dailyLimitSeconds) : 1
      let remaining = max(0, site.dailyLimitSeconds - used)
      let blocked = ledger.shouldBlock(siteID: site.id, limit: site.dailyLimitSeconds)
      let favicon = faviconLoader.image(for: site) { [weak self] in
        self?.refreshDisplay(now: Date())
      }
      statusItem.button?.image = activeSiteImage(
        favicon: favicon, fallbackLetter: String(site.name.prefix(1)).uppercased(),
        remainingFraction: 1 - usedFraction, blocked: blocked)
      statusItem.button?.toolTip =
        "\(site.name): \(format(remaining)) remaining of \(format(site.dailyLimitSeconds)) · \(Int(usedFraction * 100))% used"
    } else {
      statusItem.button?.image = idleStatusImage
      statusItem.button?.toolTip =
        configuration.sites.isEmpty
        ? "Web Time: no websites configured" : "Web Time: nothing being counted"
    }
    statusItem.button?.title = ""

    for site in configuration.sites {
      let used = ledger.consumed(siteID: site.id)
      let blocked = ledger.shouldBlock(siteID: site.id, limit: site.dailyLimitSeconds)
      let favicon = faviconLoader.image(for: site) { [weak self] in
        self?.refreshDisplay(now: Date())
      }
      siteViews[site.id]?.update(
        name: site.name, favicon: favicon, used: used, limit: site.dailyLimitSeconds,
        active: activeSiteIDs.contains(site.id), blocked: blocked)
    }

    if unlocked, let until = controlsSession.unlockedUntil {
      let minutes = max(1, Int(ceil(until.timeIntervalSince(now) / 60)))
      updateControlsStatus("Controls unlocked, relocks in \(minutes)m", symbol: "lock.open.fill")
      lockActionItem.title = "Lock controls now"
    } else {
      updateControlsStatus("Controls locked", symbol: "lock.fill")
      lockActionItem.title = "Unlock controls…"
    }
    lockActionItem.image = nil
    manageItem.isEnabled = unlocked
    quitItem.isEnabled = unlocked
  }

  private func controlsAreUnlocked(at date: Date) -> Bool {
    controlsSession.isUnlocked(at: date)
  }

  private func updateControlsStatus(_ title: String, symbol: String) {
    controlsStatusView.update(title: title, symbol: symbol)
  }

  private func touchControls() {
    controlsSession.recordInteraction(
      at: Date(), inactivityTimeout: configuration.controlsInactivitySeconds)
    refreshDisplay(now: Date())
  }

  private func lockControls() {
    controlsSession.lock()
    settingsController?.close()
    settingsController = nil
    refreshDisplay(now: Date())
  }

  @objc private func toggleControlsLock() {
    if controlsAreUnlocked(at: Date()) {
      lockControls()
      return
    }
    guard runTypingChallenge() else { return }
    controlsSession.unlock(at: Date(), inactivityTimeout: configuration.controlsInactivitySeconds)
    refreshDisplay(now: Date())
  }

  private func runTypingChallenge() -> Bool {
    let challenge = RecoveryChallenge.generate()
    let alert = NSAlert()
    alert.messageText = "Unlock controls"
    alert.informativeText =
      "Type all 12 words manually. Copy and paste is disabled. Controls relock after five minutes without interaction."
    let panel = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 94))
    let display = challenge.split(separator: " ").enumerated().map { index, word in
      index == 6 ? "\n\(word)" : String(word)
    }.joined(separator: " ")
    let phrase = NSTextField(wrappingLabelWithString: display)
    phrase.frame = NSRect(x: 0, y: 42, width: 480, height: 50)
    phrase.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    phrase.alignment = .center
    phrase.isSelectable = false
    let field = ManualEntryTextField(frame: NSRect(x: 0, y: 4, width: 480, height: 26))
    field.placeholderString = "Type all 12 words, separated by single spaces"
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.unregisterDraggedTypes()
    panel.addSubview(phrase)
    panel.addSubview(field)
    alert.accessoryView = panel
    alert.addButton(withTitle: "Unlock controls")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    guard RecoveryChallenge.matches(typed: field.stringValue, challenge: challenge) else {
      showMessage("Phrase did not match", "Controls remain locked.")
      return false
    }
    return true
  }

  @objc private func manageWebsites() {
    guard controlsAreUnlocked(at: Date()) else { return }
    touchControls()
    if let settingsController {
      settingsController.showWindow(nil)
      settingsController.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SiteSettingsWindowController(
      sites: configuration.sites, consumedBySite: ledger.usage.consumedBySite,
      faviconLoader: faviconLoader,
      onChange: { [weak self] sites in
        guard let self else { return }
        self.configuration.sites = sites
        self.lastPolicies = nil
        self.persist()
        self.syncPoliciesIfNeeded()
        self.scheduleMenuRebuild()
        self.refreshStatistics()
      },
      onInteraction: { [weak self] in self?.touchControls() },
      onClose: { [weak self] in
        guard let self else { return }
        self.settingsController = nil
        guard self.menuRebuildDeferredForSettings else { return }
        self.menuRebuildDeferredForSettings = false
        self.scheduleMenuRebuild()
      })
    settingsController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showStatistics() {
    if let statisticsController {
      refreshStatistics()
      statisticsController.showWindow(nil)
      statisticsController.window?.makeKeyAndOrderFront(nil)
    } else {
      let controller = StatisticsWindowController(
        sites: configuration.sites, history: history, faviconLoader: faviconLoader)
      statisticsController = controller
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func refreshStatistics() {
    statisticsController?.update(sites: configuration.sites, history: history)
  }

  private func scheduleMenuRebuild() {
    if settingsController?.window?.isVisible == true {
      menuRebuildDeferredForSettings = true
      return
    }
    if menuIsOpen {
      menuRankingChangedWhileOpen = true
      return
    }
    guard !menuRebuildScheduled else { return }
    menuRebuildScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.menuRebuildScheduled = false
      self.buildMenu()
    }
  }

  private func refreshMenuRankingIfNeeded() {
    guard rankedMenuSites.map(\.id) != displayedMenuSiteIDs else { return }
    scheduleMenuRebuild()
  }

  @objc private func quitApplication() {
    guard controlsAreUnlocked(at: Date()) else { return }
    touchControls()
    // Leave normal DNS forwarding enabled and clear limiter-owned PF rules before quitting.
    _ = try? daemon.send(.updatePolicies(policies(allAllowed: true)))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["bootout", "gui/\(getuid())/local.web-time.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    NSApp.terminate(nil)
  }

  private func persist() {
    try? store.save(configuration, to: "configuration.json")
    try? store.save(ledger.usage, to: "usage.json")
    try? store.save(history, to: "history.json")
  }

  private func format(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
  }

  private func foregroundProcessHints() -> [String] {
    guard let application = NSWorkspace.shared.frontmostApplication else { return [] }
    var hints = [application.localizedName].compactMap { $0?.lowercased() }
    switch application.bundleIdentifier?.lowercased() {
    case "com.apple.safari": hints += ["safari", "webkit"]
    case "com.google.chrome": hints += ["google chrome", "chrome"]
    case "org.mozilla.firefox": hints += ["firefox"]
    case "com.brave.browser": hints += ["brave browser", "brave"]
    case "com.microsoft.edgemac": hints += ["microsoft edge", "edge"]
    case "company.thebrowser.browser": hints += ["arc"]
    case "com.operasoftware.opera": hints += ["opera"]
    case "com.vivaldi.vivaldi": hints += ["vivaldi"]
    default: break
    }
    return Array(Set(hints))
  }

  private func webTimeImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      let face = NSBezierPath(ovalIn: NSRect(x: 3, y: 2.5, width: 12, height: 12))
      face.lineWidth = 1.8
      face.stroke()

      let crown = NSBezierPath()
      crown.move(to: NSPoint(x: 7.2, y: 16))
      crown.line(to: NSPoint(x: 10.8, y: 16))
      crown.move(to: NSPoint(x: 9, y: 14.5))
      crown.line(to: NSPoint(x: 9, y: 16))
      crown.move(to: NSPoint(x: 13.2, y: 13.2))
      crown.line(to: NSPoint(x: 14.5, y: 14.5))
      crown.lineWidth = 1.8
      crown.lineCapStyle = .round
      crown.stroke()

      let hand = NSBezierPath()
      hand.move(to: NSPoint(x: 9, y: 8.5))
      hand.line(to: NSPoint(x: 11.5, y: 11.7))
      hand.lineWidth = 1.65
      hand.lineCapStyle = .round
      hand.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Web Time"
    return image
  }

  private func activeSiteImage(
    favicon: NSImage?, fallbackLetter: String, remainingFraction: Double, blocked: Bool
  ) -> NSImage {
    let visibleFraction = min(1, max(0, remainingFraction))
    let ringColor: NSColor = blocked || visibleFraction <= 0.1 ? .systemRed : .white
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      let iconRect = NSRect(x: 3, y: 3, width: 12, height: 12)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: iconRect, xRadius: 2.8, yRadius: 2.8).addClip()
      if let favicon {
        favicon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
      } else {
        NSColor.white.setFill()
        iconRect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 10, weight: .bold),
          .foregroundColor: NSColor.black,
        ]
        let text = NSAttributedString(string: fallbackLetter, attributes: attributes)
        text.draw(at: NSPoint(x: iconRect.midX - text.size().width / 2, y: iconRect.midY - 6))
      }
      NSGraphicsContext.restoreGraphicsState()

      let ringRect = NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5)
      guard visibleFraction > 0 else { return true }
      let progress = NSBezierPath()
      progress.appendArc(
        withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
        startAngle: 90, endAngle: 90 + 360 * CGFloat(visibleFraction), clockwise: false)
      ringColor.setStroke()
      progress.lineWidth = 1.6
      progress.lineCapStyle = .round
      progress.stroke()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Website currently being counted"
    return image
  }

  private func showMessage(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.runModal()
  }
}

private let singleInstanceLock: SingleInstanceLock? = {
  do {
    return try SingleInstanceLock()
  } catch SingleInstanceLockError.alreadyRunning {
    exit(EXIT_SUCCESS)
  } catch {
    // A lock-system failure should not make the limiter unavailable.
    return nil
  }
}()
private let application = NSApplication.shared
private let controller = AppController()
application.delegate = controller
application.run()
