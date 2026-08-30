import AppKit
import QuartzCore
import WebTimeCore

private struct UsageChartBar {
  var label: String
  var values: [TimeInterval]
}

@MainActor
private final class StatisticsBackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.underPageBackgroundColor.setFill()
    NSBezierPath(rect: dirtyRect).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
private final class UsageChartView: NSView {
  var bars: [UsageChartBar] = [] { didSet { needsDisplay = true } }
  var colors: [NSColor] = [] { didSet { needsDisplay = true } }
  var selectedIndex: Int? { didSet { needsDisplay = true } }
  var colorsOnlySelected = false { didSet { needsDisplay = true } }
  var sectionTitle = "" { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    NSAttributedString(string: sectionTitle, attributes: titleAttributes).draw(
      at: NSPoint(x: 0, y: bounds.maxY - 15))

    let plot = NSRect(x: 4, y: 19, width: bounds.width - 44, height: bounds.height - 39)
    guard plot.width > 0, plot.height > 0 else { return }
    let maximum = max(60, bars.map { $0.values.reduce(0, +) }.max() ?? 0)
    let gridColor = NSColor.separatorColor.withAlphaComponent(0.52)
    let axisAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
      .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    for step in 0...2 {
      let fraction = CGFloat(step) / 2
      let y = plot.minY + plot.height * fraction
      let line = NSBezierPath()
      line.move(to: NSPoint(x: plot.minX, y: y))
      line.line(to: NSPoint(x: plot.maxX, y: y))
      line.lineWidth = 0.5
      gridColor.setStroke()
      line.stroke()
      let value = maximum * Double(step) / 2
      NSAttributedString(string: compactDuration(value), attributes: axisAttributes).draw(
        at: NSPoint(x: plot.maxX + 6, y: y - 6))
    }
    guard !bars.isEmpty else { return }
    let slot = plot.width / CGFloat(bars.count)
    let barWidth = min(bars.count > 12 ? 12 : 36, max(3, slot * 0.58))
    for (index, bar) in bars.enumerated() {
      let x = plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2
      var y = plot.minY
      let visibleIndices = bar.values.indices.filter { bar.values[$0] > 0 }
      let topIndex = visibleIndices.last
      for valueIndex in visibleIndices {
        let value = bar.values[valueIndex]
        let height = max(1, plot.height * CGFloat(value / maximum))
        let rect = NSRect(x: x, y: y, width: barWidth, height: min(height, plot.maxY - y))
        let segmentColor: NSColor =
          colorsOnlySelected && selectedIndex != index
          ? .tertiaryLabelColor
          : (colors.indices.contains(valueIndex) ? colors[valueIndex] : .systemBlue)
        segmentColor.setFill()
        if valueIndex == topIndex {
          topRoundedPath(rect, radius: min(3, rect.width / 2, rect.height)).fill()
        } else {
          NSBezierPath(rect: rect).fill()
        }
        y += height
      }
      if selectedIndex == index {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x, y: plot.minY - 4))
        marker.line(to: NSPoint(x: x + barWidth, y: plot.minY - 4))
        marker.lineWidth = 2
        marker.lineCapStyle = .round
        marker.stroke()
      }
      guard !bar.label.isEmpty else { continue }
      let label = NSAttributedString(string: bar.label, attributes: axisAttributes)
      label.draw(
        at: NSPoint(x: x + (barWidth - label.size().width) / 2, y: plot.minY - 17))
    }
  }

  private func compactDuration(_ seconds: TimeInterval) -> String {
    if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))h" }
    return "\(max(0, Int(ceil(seconds / 60))))m"
  }

  private func topRoundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
    path.appendArc(
      withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
      startAngle: 0, endAngle: 90)
    path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
    path.appendArc(
      withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
      startAngle: 90, endAngle: 180)
    path.close()
    return path
  }
}

@MainActor
final class StatisticsWindowController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private var sites: [SiteConfiguration]
  private var history: UsageHistory
  private let faviconLoader: FaviconLoader
  private var selectedDate = Calendar.current.startOfDay(for: Date())
  private var filteredSites: [SiteConfiguration] = []

  private let updatedLabel = NSTextField(labelWithString: "")
  private let totalLabel = NSTextField(labelWithString: "0m")
  private let dateLabel = NSTextField(labelWithString: "Today")
  private let previousButton = NSButton()
  private let todayButton = NSButton(title: "Today", target: nil, action: nil)
  private let nextButton = NSButton()
  private let weeklyChart = UsageChartView()
  private let hourlyChart = UsageChartView()
  private let table = NSTableView()
  private let search = NSSearchField()
  private let palette: [NSColor] = [
    .systemBlue, .systemTeal, .systemOrange, .systemPurple, .systemPink, .systemIndigo,
    .systemGreen,
  ]

  init(sites: [SiteConfiguration], history: UsageHistory, faviconLoader: FaviconLoader) {
    self.sites = sites
    self.history = history
    self.faviconLoader = faviconLoader
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Web Time Statistics"
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.backgroundColor = .underPageBackgroundColor
    let content = StatisticsBackgroundView(frame: window.contentView?.bounds ?? .zero)
    content.autoresizingMask = [.width, .height]
    window.contentView = content
    window.center()
    super.init(window: window)
    buildUI(in: content)
    refresh(animated: false)
  }

  required init?(coder: NSCoder) { nil }

  func update(sites: [SiteConfiguration], history: UsageHistory) {
    self.sites = sites
    self.history = history
    refresh(animated: false)
  }

  private func buildUI(in content: NSView) {
    let title = NSTextField(labelWithString: "App & Website Activity")
    title.frame = NSRect(x: 28, y: 663, width: 440, height: 30)
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    updatedLabel.frame = NSRect(x: 28, y: 643, width: 440, height: 20)
    updatedLabel.font = .systemFont(ofSize: 12, weight: .regular)
    updatedLabel.textColor = .secondaryLabelColor
    content.addSubview(title)
    content.addSubview(updatedLabel)

    let usagePanel = panel(frame: NSRect(x: 24, y: 286, width: 812, height: 342))
    let usageTitle = NSTextField(labelWithString: "Usage")
    usageTitle.frame = NSRect(x: 20, y: 297, width: 140, height: 24)
    usageTitle.font = .systemFont(ofSize: 15, weight: .semibold)
    totalLabel.frame = NSRect(x: 20, y: 250, width: 250, height: 48)
    totalLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .regular)
    dateLabel.frame = NSRect(x: 392, y: 287, width: 180, height: 24)
    dateLabel.font = .systemFont(ofSize: 14, weight: .medium)
    dateLabel.alignment = .right

    configureNavigationButton(
      previousButton, symbol: "chevron.left", action: #selector(previousDay))
    previousButton.frame = NSRect(x: 586, y: 282, width: 38, height: 32)
    todayButton.target = self
    todayButton.action = #selector(goToToday)
    todayButton.bezelStyle = .rounded
    todayButton.frame = NSRect(x: 630, y: 282, width: 94, height: 32)
    configureNavigationButton(nextButton, symbol: "chevron.right", action: #selector(nextDay))
    nextButton.frame = NSRect(x: 730, y: 282, width: 38, height: 32)

    weeklyChart.frame = NSRect(x: 20, y: 132, width: 772, height: 108)
    weeklyChart.sectionTitle = "WEEK"
    weeklyChart.colorsOnlySelected = true
    hourlyChart.frame = NSRect(x: 20, y: 18, width: 772, height: 102)
    hourlyChart.sectionTitle = "DAY"
    [
      usageTitle, totalLabel, dateLabel, previousButton, todayButton, nextButton, weeklyChart,
      hourlyChart,
    ]
    .forEach(usagePanel.addSubview)
    content.addSubview(usagePanel)

    let listPanel = panel(frame: NSRect(x: 24, y: 22, width: 812, height: 244))
    let websitesTitle = NSTextField(labelWithString: "Websites")
    websitesTitle.frame = NSRect(x: 20, y: 201, width: 180, height: 24)
    websitesTitle.font = .systemFont(ofSize: 15, weight: .semibold)
    search.frame = NSRect(x: 562, y: 195, width: 230, height: 28)
    search.placeholderString = "Search"
    search.delegate = self

    let columns = [
      ("website", "Website", 420.0), ("time", "Time", 160.0), ("limit", "Daily Limit", 165.0),
    ]
    for (identifier, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.delegate = self
    table.dataSource = self
    table.rowHeight = 38
    table.frame = NSRect(x: 0, y: 0, width: 772, height: 168)
    table.headerView = NSTableHeaderView()
    table.usesAlternatingRowBackgroundColors = true
    table.allowsEmptySelection = true
    table.allowsMultipleSelection = false
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 16, width: 772, height: 168))
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    listPanel.addSubview(websitesTitle)
    listPanel.addSubview(search)
    listPanel.addSubview(scroll)
    content.addSubview(listPanel)
  }

  private func panel(frame: NSRect) -> NSBox {
    let box = NSBox(frame: frame)
    box.boxType = .custom
    box.cornerRadius = 12
    box.borderWidth = 0.5
    box.borderColor = .separatorColor
    box.fillColor = .controlBackgroundColor
    return box
  }

  private func configureNavigationButton(_ button: NSButton, symbol: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imagePosition = .imageOnly
    button.bezelStyle = .rounded
    button.target = self
    button.action = action
  }

  @objc private func previousDay() {
    selectedDate =
      Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    refresh(animated: true)
  }

  @objc private func nextDay() {
    let candidate =
      Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    selectedDate = min(Calendar.current.startOfDay(for: Date()), candidate)
    refresh(animated: true)
  }

  @objc private func goToToday() {
    selectedDate = Calendar.current.startOfDay(for: Date())
    refresh(animated: true)
  }

  func controlTextDidChange(_ obj: Notification) { refreshTable() }

  func numberOfRows(in tableView: NSTableView) -> Int { filteredSites.count + 1 }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let column = tableColumn else { return nil }
    let totals = history.days[dayKey(selectedDate), default: [:]]
    if row == 0 {
      switch column.identifier.rawValue {
      case "website": return websiteCell(name: "All Websites", site: nil, emphasized: true)
      case "time": return textCell(duration(totals.values.reduce(0, +)), emphasized: true)
      case "limit": return textCell("—", emphasized: true)
      default: return nil
      }
    }
    guard filteredSites.indices.contains(row - 1) else { return nil }
    let site = filteredSites[row - 1]
    switch column.identifier.rawValue {
    case "website": return websiteCell(name: site.name, site: site, emphasized: false)
    case "time": return textCell(duration(totals[site.id, default: 0]), emphasized: false)
    case "limit": return textCell(duration(site.dailyLimitSeconds), emphasized: false)
    default: return nil
    }
  }

  private func websiteCell(name: String, site: SiteConfiguration?, emphasized: Bool) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 38))
    let icon = FaviconTileView(frame: NSRect(x: 5, y: 4, width: 30, height: 30))
    if let site {
      icon.image =
        faviconLoader.image(for: site) { [weak self] in self?.table.reloadData() }
        ?? NSImage(systemSymbolName: "globe", accessibilityDescription: site.name)
    } else {
      icon.image = NSImage(
        systemSymbolName: "chart.bar.fill", accessibilityDescription: "All websites")
      icon.contentTintColor = .controlAccentColor
    }
    let label = NSTextField(labelWithString: name)
    label.frame = NSRect(x: 45, y: 8, width: 350, height: 22)
    label.font = .systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
    view.addSubview(icon)
    view.addSubview(label)
    return view
  }

  private func textCell(_ value: String, emphasized: Bool) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 38))
    let field = NSTextField(labelWithString: value)
    field.frame = NSRect(x: 0, y: 8, width: 148, height: 22)
    field.font = .monospacedDigitSystemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
    field.lineBreakMode = .byTruncatingTail
    container.addSubview(field)
    return container
  }

  private func refresh(animated: Bool) {
    let now = Date()
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    updatedLabel.stringValue = "Updated today at \(formatter.string(from: now))"
    dateLabel.stringValue = dateDescription(selectedDate)
    let today = Calendar.current.startOfDay(for: now)
    nextButton.isEnabled = selectedDate < today
    todayButton.isEnabled = selectedDate != today

    let totals = history.days[dayKey(selectedDate), default: [:]]
    totalLabel.stringValue = duration(totals.values.reduce(0, +))
    let orderedSites = sites
    let colors = orderedSites.indices.map { palette[$0 % palette.count] }
    weeklyChart.colors = colors
    hourlyChart.colors = colors

    let calendar = Calendar.current
    let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
    let weekday = DateFormatter()
    weekday.dateFormat = "EEEEE"
    let weekDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    weeklyChart.bars = weekDates.map { date in
      let values = history.days[dayKey(date), default: [:]]
      return UsageChartBar(
        label: weekday.string(from: date), values: orderedSites.map { values[$0.id, default: 0] })
    }
    weeklyChart.selectedIndex = weekDates.firstIndex {
      calendar.isDate($0, inSameDayAs: selectedDate)
    }

    let hours = history.hourly[dayKey(selectedDate), default: [:]]
    hourlyChart.bars = (0..<24).map { hour in
      let values = hours[String(format: "%02d", hour), default: [:]]
      return UsageChartBar(
        label: hour % 6 == 0 ? String(format: "%02d", hour) : "",
        values: orderedSites.map { values[$0.id, default: 0] })
    }
    hourlyChart.selectedIndex = nil
    refreshTable()

    if animated {
      weeklyChart.alphaValue = 0.35
      hourlyChart.alphaValue = 0.35
      table.alphaValue = 0.55
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        weeklyChart.animator().alphaValue = 1
        hourlyChart.animator().alphaValue = 1
        table.animator().alphaValue = 1
      }
    }
  }

  private func refreshTable() {
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let totals = history.days[dayKey(selectedDate), default: [:]]
    filteredSites = sites.filter { site in
      query.isEmpty || site.name.localizedCaseInsensitiveContains(query)
        || site.primaryDomain.localizedCaseInsensitiveContains(query)
    }.sorted { totals[$0.id, default: 0] > totals[$1.id, default: 0] }
    table.reloadData()
  }

  private func dayKey(_ date: Date) -> String { UsageLedger.dayKey(for: date) }

  private func dateDescription(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, d MMMM"
    return formatter.string(from: date)
  }

  private func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds.rounded()) / 60)
    if minutes >= 60 {
      let remainder = minutes % 60
      return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }
    return "\(minutes)m"
  }
}
