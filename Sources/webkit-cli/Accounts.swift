import Foundation

/// WebKit keys persistent stores by the executable name: ~/Library/WebKit/<name>/WebsiteDataStore/<uuid>.
/// A renamed binary silently sees none of the existing accounts, so the name is pinned.
let pinnedExecutableName = "webkit-cli"

struct Accounts {
  static let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/webkit-cli", isDirectory: true)
  static let accountsFile = configDir.appendingPathComponent("accounts.json")
  static let sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)

  private(set) var byName: [String: UUID]

  static func load() throws -> Accounts {
    try ensurePrivateDir(configDir)
    guard FileManager.default.fileExists(atPath: accountsFile.path) else { return Accounts(byName: [:]) }
    let data = try Data(contentsOf: accountsFile)
    let raw: [String: String]
    do {
      raw = try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      throw CLIError("\(accountsFile.path) is not a JSON object of name → uuid: \(error)")
    }
    var byName: [String: UUID] = [:]
    for (name, id) in raw {
      guard let uuid = UUID(uuidString: id) else {
        throw CLIError("\(accountsFile.path): account '\(name)' has invalid uuid '\(id)'")
      }
      byName[name] = uuid
    }
    return Accounts(byName: byName)
  }

  func id(of name: String) throws -> UUID {
    guard let id = byName[name] else {
      throw CLIError("no account '\(name)' — create it with: webkit-cli auth <url> --account \(name)")
    }
    return id
  }

  mutating func create(_ name: String) throws -> UUID {
    try Accounts.validate(name)
    if let existing = byName[name] { return existing }
    let id = UUID()
    byName[name] = id
    try save()
    return id
  }

  mutating func remove(_ name: String) throws {
    guard byName.removeValue(forKey: name) != nil else { throw CLIError("no account '\(name)'") }
    try save()
  }

  private func save() throws {
    let raw = byName.mapValues(\.uuidString)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(try enc.encode(raw), to: Accounts.accountsFile)
  }

  static func validate(_ name: String) throws {
    let ok = !name.isEmpty && name != "-" && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }
    guard ok else { throw CLIError("invalid account name '\(name)' — use letters, digits, . _ - @", code: ExitCode.usage) }
  }

  static func sessionFile(for id: UUID) -> URL {
    sessionsDir.appendingPathComponent("\(id.uuidString).plist")
  }

  static func requirePinnedExecutableName() throws {
    let name = ProcessInfo.processInfo.processName
    guard name == pinnedExecutableName else {
      throw CLIError("""
        this binary is running as '\(name)' but must be named '\(pinnedExecutableName)'. \
        WebKit stores account data under ~/Library/WebKit/<executable-name>/, so a renamed binary \
        would not see your accounts. Rename or symlink it back to '\(pinnedExecutableName)'.
        """)
    }
  }
}

func ensurePrivateDir(_ url: URL) throws {
  let fm = FileManager.default
  try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Writes a 0600 file into an existing directory the caller chose (we don't tighten its permissions).
func writePrivateFile(_ data: Data, to url: URL) throws {
  let dir = url.deletingLastPathComponent()
  guard FileManager.default.fileExists(atPath: dir.path) else { throw CLIError("directory does not exist: \(dir.path)") }
  try? FileManager.default.removeItem(at: url)
  guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    throw CLIError("could not write \(url.path)")
  }
}

func writePrivate(_ data: Data, to url: URL) throws {
  try ensurePrivateDir(url.deletingLastPathComponent())
  let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
  guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    throw CLIError("could not write \(tmp.path)")
  }
  guard rename(tmp.path, url.path) == 0 else {
    let err = String(cString: strerror(errno))
    try? FileManager.default.removeItem(at: tmp)
    throw CLIError("could not move \(tmp.path) → \(url.path): \(err)")
  }
}
