import AppKit
import Foundation

private enum SetupAction: String {
  case install
  case uninstall

  var progressTitle: String {
    switch self {
    case .install: "Installing Web Time"
    case .uninstall: "Uninstalling Web Time"
    }
  }

  var successMessage: String {
    switch self {
    case .install: "Web Time is installed and running."
    case .uninstall: "Web Time was removed and the previous DNS settings were restored."
    }
  }
}

private struct SetupFailure: Error {
  let message: String
}

@main
@MainActor
private struct WebTimeSetup {
  static func main() {
    let application = NSApplication.shared
    let delegate = SetupDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    withExtendedLifetime(delegate) {}
  }
}

@MainActor
private final class SetupDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async { [weak self] in self?.presentSetupChoice() }
  }

  // This app only presents modal alerts, so closing an alert must not be interpreted as
  // closing the setup app's last window. The setup flow terminates explicitly after it
  // finishes, fails, or is canceled.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  private func presentSetupChoice() {
    let alert = NSAlert()
    alert.messageText = "Web Time Setup"
    alert.informativeText =
      "Install Web Time and its local DNS service, or remove Web Time and restore the previous DNS settings. macOS will ask for an administrator password."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Uninstall…")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()
    DispatchQueue.main.async { [weak self] in
      switch response {
      case .alertFirstButtonReturn: self?.perform(.install)
      case .alertSecondButtonReturn: self?.confirmUninstall()
      default: NSApp.terminate(nil)
      }
    }
  }

  private func confirmUninstall() {
    let alert = NSAlert()
    alert.messageText = "Uninstall Web Time?"
    alert.informativeText =
      "Web Time will restore the DNS settings captured during installation, then remove the app, helper, settings, and usage history."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    DispatchQueue.main.async { [weak self] in
      if response == .alertFirstButtonReturn {
        self?.perform(.uninstall)
      } else {
        NSApp.terminate(nil)
      }
    }
  }

  private func perform(_ action: SetupAction) {
    do {
      let archive = try makePayloadArchive()
      defer { try? FileManager.default.removeItem(at: archive.url) }
      try authorize(action: action, archive: archive.url, expectedHash: archive.sha256)
      presentResult(title: action.progressTitle, message: action.successMessage, style: .informational)
    } catch let failure as SetupFailure {
      if failure.message == "User canceled." {
        NSApp.terminate(nil)
        return
      }
      presentResult(title: "Setup could not finish", message: failure.message, style: .warning)
    } catch {
      presentResult(title: "Setup could not finish", message: error.localizedDescription, style: .warning)
    }
    NSApp.terminate(nil)
  }

  private func makePayloadArchive() throws -> (url: URL, sha256: String) {
    guard let resources = Bundle.main.resourceURL else {
      throw SetupFailure(message: "The setup resources are missing.")
    }
    let payload = resources.appendingPathComponent("Payload", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: payload.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SetupFailure(message: "The setup payload is missing.")
    }

    let archive = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("web-time-setup-\(UUID().uuidString).zip")
    let archiveResult = run(
      "/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", payload.path, archive.path])
    guard archiveResult.status == 0 else {
      throw SetupFailure(message: "The setup payload could not be prepared.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)

    let hashResult = run("/usr/bin/shasum", arguments: ["-a", "256", archive.path])
    guard hashResult.status == 0,
      let hash = hashResult.output.split(whereSeparator: \Character.isWhitespace).first.map(String.init),
      hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else {
      try? FileManager.default.removeItem(at: archive)
      throw SetupFailure(message: "The setup payload could not be verified.")
    }
    return (archive, hash)
  }

  private func authorize(action: SetupAction, archive: URL, expectedHash: String) throws {
    guard let script = Bundle.main.resourceURL?.appendingPathComponent("authorized-action.sh"),
      FileManager.default.fileExists(atPath: script.path)
    else {
      throw SetupFailure(message: "The authorization helper is missing.")
    }
    let command = [
      "/bin/bash", shellQuote(script.path), action.rawValue, shellQuote(archive.path), expectedHash,
    ].joined(separator: " ")
    let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    let result = run("/usr/bin/osascript", arguments: ["-e", source])
    guard result.status == 0 else {
      let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      if message.localizedCaseInsensitiveContains("user canceled") || message.contains("(-128)") {
        throw SetupFailure(message: "User canceled.")
      }
      throw SetupFailure(
        message: message.isEmpty ? "The administrator action failed." : message)
    }
  }

  private func run(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return (-1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func appleScriptLiteral(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  private func presentResult(title: String, message: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
