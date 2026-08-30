import Foundation

public enum DurationText {
  public static func compact(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds.rounded()) / 60)
    guard minutes >= 60 else { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }
}
