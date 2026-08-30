import AppKit
import WebTimeCore

@MainActor
final class SiteSettingsWindowController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate, NSWindowDelegate
{
  private var sites: [SiteConfiguration]
  private let consumedBySite: [String: TimeInterval]
  private let faviconLoader: FaviconLoader
  private let table = NSTableView()
  private let onChange: ([SiteConfiguration]) -> Void
  private let onInteraction: () -> Void
  private let onClose: () -> Void

  init(
    sites: [SiteConfiguration], consumedBySite: [String: TimeInterval],
    faviconLoader: FaviconLoader,
    onChange: @escaping ([SiteConfiguration]) -> Void, onInteraction: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    self.sites = sites
    self.consumedBySite = consumedBySite
    self.faviconLoader = faviconLoader
    self.onChange = onChange
    self.onInteraction = onInteraction
    self.onClose = onClose
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 390),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Tracked Websites"
    window.center()
    super.init(window: window)
    window.delegate = self
    buildUI(in: window.contentView!)
  }

  required init?(coder: NSCoder) { nil }

  private func buildUI(in content: NSView) {
    let intro = NSTextField(
      wrappingLabelWithString:
        "Enter a website and its daily allowance. Web Time tracks that domain and its subdomains, and learns current IP addresses automatically."
    )
    intro.frame = NSRect(x: 20, y: 342, width: 640, height: 34)
    content.addSubview(intro)

    let columns = [
      ("name", "Website", 205.0), ("domains", "Address", 205.0),
      ("limit", "Daily allowance", 110.0), ("used", "Used today", 95.0),
    ]
    for (id, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.delegate = self
    table.dataSource = self
    table.allowsMultipleSelection = false
    table.usesAlternatingRowBackgroundColors = true
    table.headerView = NSTableHeaderView()
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 640, height: 270))
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    content.addSubview(scroll)

    let add = NSButton(title: "Add…", target: self, action: #selector(addSite))
    add.frame = NSRect(x: 20, y: 18, width: 80, height: 30)
    let edit = NSButton(title: "Edit…", target: self, action: #selector(editSite))
    edit.frame = NSRect(x: 108, y: 18, width: 80, height: 30)
    let remove = NSButton(title: "Remove", target: self, action: #selector(removeSite))
    remove.frame = NSRect(x: 196, y: 18, width: 80, height: 30)
    let done = NSButton(title: "Done", target: self, action: #selector(done))
    done.keyEquivalent = "\r"
    done.frame = NSRect(x: 580, y: 18, width: 80, height: 30)
    [add, edit, remove, done].forEach(content.addSubview)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard sites.indices.contains(row), let column = tableColumn else { return nil }
    let site = sites[row]
    if column.identifier.rawValue == "name" {
      return websiteCell(for: site)
    }
    let value: String
    switch column.identifier.rawValue {
    case "domains": value = site.primaryDomain
    case "limit": value = DurationText.compact(site.dailyLimitSeconds)
    case "used": value = DurationText.compact(consumedBySite[site.id, default: 0])
    default: value = ""
    }
    let field = NSTextField(labelWithString: value)
    field.lineBreakMode = .byTruncatingTail
    field.toolTip = value
    return field
  }

  func tableViewSelectionDidChange(_ notification: Notification) { onInteraction() }
  func windowDidBecomeKey(_ notification: Notification) { onInteraction() }
  func windowWillClose(_ notification: Notification) {
    onInteraction()
    onClose()
  }

  @objc private func addSite() {
    onInteraction()
    guard let site = editDialog(site: nil) else { return }
    sites.append(site)
    faviconLoader.prefetch(for: site) { [weak self] in self?.table.reloadData() }
    changed(selecting: sites.count - 1)
  }

  @objc private func editSite() {
    onInteraction()
    guard sites.indices.contains(table.selectedRow),
      let edited = editDialog(site: sites[table.selectedRow])
    else { return }
    sites[table.selectedRow] = edited
    faviconLoader.prefetch(for: edited) { [weak self] in self?.table.reloadData() }
    changed(selecting: table.selectedRow)
  }

  @objc private func removeSite() {
    onInteraction()
    guard sites.indices.contains(table.selectedRow) else { return }
    let site = sites[table.selectedRow]
    let alert = NSAlert()
    alert.messageText = "Stop tracking \(site.name)?"
    alert.informativeText =
      "Its saved usage history is retained, but network tracking and blocking stop immediately."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard runModalTrackingInteraction(alert) == .alertFirstButtonReturn else { return }
    sites.remove(at: table.selectedRow)
    changed(selecting: min(table.selectedRow, sites.count - 1))
  }

  @objc private func done() {
    onInteraction()
    close()
  }

  private func changed(selecting row: Int) {
    table.reloadData()
    if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    onInteraction()
    onChange(sites)
  }

  private func editDialog(site: SiteConfiguration?) -> SiteConfiguration? {
    let alert = NSAlert()
    alert.messageText = site == nil ? "Add a tracked website" : "Edit tracked website"
    alert.informativeText =
      "Paste a website address. Add any separate domains that should share its allowance under Extra domains."
    let panel = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 148))
    let name = labeledField("Name (optional)", value: site?.name ?? "", y: 114, in: panel)
    let website = labeledField("Website or URL", value: site?.primaryDomain ?? "", y: 78, in: panel)
    let extraDomains = labeledField(
      "Extra domains",
      value: site.map { Array($0.domains.dropFirst()).joined(separator: ", ") } ?? "",
      y: 42, in: panel)
    extraDomains.placeholderString = "Optional, separated by commas"
    let minutes = labeledField(
      "Minutes/day", value: site.map { String(Int($0.dailyLimitSeconds / 60)) } ?? "60", y: 6,
      in: panel)
    alert.accessoryView = panel
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard runModalTrackingInteraction(alert) == .alertFirstButtonReturn else { return nil }
    let primaryDomain = SiteDomains.normalize(website.stringValue)
    let optionalDomains = extraDomains.stringValue.split(separator: ",").map {
      SiteDomains.normalize(String($0))
    }
    guard SiteDomains.isValid(primaryDomain), let minuteCount = Int(minutes.stringValue),
      (1...1440).contains(minuteCount), optionalDomains.allSatisfy(SiteDomains.isValid)
    else {
      let error = NSAlert()
      error.messageText = "Check the website details"
      error.informativeText =
        "Enter valid website addresses, separate extra domains with commas, and use 1–1440 minutes."
      _ = runModalTrackingInteraction(error)
      return nil
    }
    let typedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return SiteConfiguration(
      id: site?.id ?? UUID().uuidString,
      name: typedName.isEmpty ? SiteDomains.fallbackName(for: primaryDomain) : typedName,
      domains: SiteDomains.normalizedUnique([primaryDomain] + optionalDomains),
      dailyLimitSeconds: TimeInterval(minuteCount * 60))
  }

  private func websiteCell(for site: SiteConfiguration) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    let icon = FaviconTileView(frame: NSRect(x: 2, y: 0, width: 24, height: 24))
    icon.image =
      faviconLoader.image(for: site) { [weak self] in self?.table.reloadData() }
      ?? NSImage(systemSymbolName: "globe", accessibilityDescription: site.name)
    let label = NSTextField(labelWithString: site.name)
    label.frame = NSRect(x: 31, y: 2, width: 166, height: 20)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = site.name
    container.addSubview(icon)
    container.addSubview(label)
    return container
  }

  private func labeledField(_ label: String, value: String, y: CGFloat, in panel: NSView)
    -> NSTextField
  {
    let title = NSTextField(labelWithString: label)
    title.frame = NSRect(x: 0, y: y + 3, width: 120, height: 20)
    let field = NSTextField(string: value)
    field.frame = NSRect(x: 126, y: y, width: 344, height: 24)
    panel.addSubview(title)
    panel.addSubview(field)
    return field
  }

  private func runModalTrackingInteraction(_ alert: NSAlert) -> NSApplication.ModalResponse {
    onInteraction()
    let response = alert.runModal()
    onInteraction()
    return response
  }

}
