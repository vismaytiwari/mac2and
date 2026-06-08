import Foundation

struct AppConfig {
  let authToken: String
  let appPassword: String?
  let ngrokAuthToken: String?
  let ngrokDomain: String?
  let ngrokBinary: String?
  let envFile: String?
  let serverPort: UInt16
  let clipboardPollSeconds: TimeInterval
  let maxClipSizeBytes: Int

  var cryptoPassword: String {
    appPassword ?? authToken
  }

  static func load() -> AppConfig {
    let envFile = EnvFile.resolvePath()
    let env = EnvFile.load(path: envFile)
    let processEnv = ProcessInfo.processInfo.environment

    func envValue(_ key: String) -> String? {
      if let value = processEnv[key], !value.isEmpty { return value }
      if let value = env[key], !value.isEmpty { return value }
      return nil
    }

    let persisted = PersistedConfigStore.loadOrCreate()
    let portValue = UInt16(envValue("SERVER_PORT") ?? "") ?? 0

    return AppConfig(
      authToken: persisted.authToken,
      appPassword: envValue("APP_PASSWORD"),
      ngrokAuthToken: envValue("NGROK_AUTHTOKEN"),
      ngrokDomain: envValue("NGROK_DOMAIN"),
      ngrokBinary: envValue("NGROK_BIN"),
      envFile: envFile,
      serverPort: portValue,
      clipboardPollSeconds: 2,
      maxClipSizeBytes: 500 * 1024
    )
  }
}

enum EnvFile {
  static func resolvePath(
    explicit: String? = ProcessInfo.processInfo.environment["MAC2AND_ENV_FILE"],
    currentDirectory: String = FileManager.default.currentDirectoryPath,
    bundleURL: URL? = Bundle.main.bundleURL,
    executablePath: String? = CommandLine.arguments.first
  ) -> String {
    var candidates: [URL] = []

    if let explicit, !explicit.isEmpty {
      candidates.append(URL(fileURLWithPath: explicit))
    }

    candidates.append(URL(fileURLWithPath: currentDirectory).appendingPathComponent(".env"))

    if let bundleURL {
      candidates.append(contentsOf: envCandidatesNear(url: bundleURL))
    }

    if let executablePath, !executablePath.isEmpty {
      let executableURL = URL(fileURLWithPath: executablePath)
      candidates.append(contentsOf: envCandidatesNear(url: executableURL))
    }

    for candidate in candidates {
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate.path
      }
    }

    return candidates.first?.path ?? URL(fileURLWithPath: currentDirectory).appendingPathComponent(".env").path
  }

  private static func envCandidatesNear(url: URL) -> [URL] {
    var candidates: [URL] = []
    var cursor = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

    for _ in 0..<8 {
      candidates.append(cursor.appendingPathComponent(".env"))
      cursor.deleteLastPathComponent()
    }

    return candidates
  }

  static func load(path: String?) -> [String: String] {
    guard let path, FileManager.default.fileExists(atPath: path) else {
      return [:]
    }

    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      return [:]
    }

    var values: [String: String] = [:]
    for line in raw.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }

      let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
      var value = String(trimmed[trimmed.index(after: eq)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if value.count >= 2 {
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
          value.removeFirst()
          value.removeLast()
        }
      }

      if !key.isEmpty {
        values[key] = value
      }
    }

    return values
  }
}

struct PersistedConfig: Codable {
  let authToken: String
}

enum PersistedConfigStore {
  static func loadOrCreate() -> PersistedConfig {
    let url = configURL()

    if
      let data = try? Data(contentsOf: url),
      let parsed = try? JSONDecoder().decode(PersistedConfig.self, from: data),
      !parsed.authToken.isEmpty
    {
      return parsed
    }

    let created = PersistedConfig(authToken: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    save(created, to: url)
    return created
  }

  private static func save(_ config: PersistedConfig, to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(config)
      try data.write(to: url, options: [.atomic])
    } catch {
      NSLog("[config] Could not persist auth token: \(error)")
    }
  }

  private static func configURL() -> URL {
    let fm = FileManager.default
    if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      return base.appendingPathComponent("Mac2And", isDirectory: true)
        .appendingPathComponent("mac2and-config.json")
    }
    return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("mac2and-config.json")
  }
}
