import Foundation

public struct JSONStore: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  public func save<T: Encodable>(_ value: T, to name: String) throws {
    let data = try JSONEncoder().encode(value)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
