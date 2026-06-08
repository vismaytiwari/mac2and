import Foundation

final class NgrokTunnel: @unchecked Sendable {
  enum TunnelError: Error, CustomStringConvertible {
    case missingToken
    case missingBinary
    case launchFailed(String)

    var description: String {
      switch self {
      case .missingToken:
        "NGROK_AUTHTOKEN is not set in .env or the environment."
      case .missingBinary:
        "ngrok CLI was not found. Install it or set NGROK_BIN in .env."
      case .launchFailed(let message):
        "ngrok failed to launch: \(message)"
      }
    }
  }

  private let config: AppConfig
  private var process: Process?
  private var outputPipe: Pipe?
  private var discoveryWorkItem: DispatchWorkItem?

  init(config: AppConfig) throws {
    self.config = config
    if config.ngrokAuthToken == nil {
      throw TunnelError.missingToken
    }
    if findNgrokBinary() == nil {
      throw TunnelError.missingBinary
    }
  }

  func start(
    port: UInt16,
    onURL: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) throws {
    guard let binary = findNgrokBinary() else {
      throw TunnelError.missingBinary
    }
    guard let token = config.ngrokAuthToken else {
      throw TunnelError.missingToken
    }

    let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("Mac2And", isDirectory: true)
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let configPath = supportDir.appendingPathComponent("ngrok.yml")
    try """
    version: "3"
    agent:
      authtoken: \(token)
    """.write(to: configPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.environment = [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": NSHomeDirectory(),
    ]
    var args = [
      "http",
      "--log=stdout",
      "--log-format=json",
      "--config",
      configPath.path,
    ]
    if let domain = config.ngrokDomain, !domain.isEmpty {
      args += ["--domain", domain]
    }
    args.append("127.0.0.1:\(port)")
    process.arguments = args

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    outputPipe = pipe

    let emittedURL = OnceFlag()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      for line in text.split(whereSeparator: \.isNewline) {
        if let url = Self.extractURL(from: String(line)), emittedURL.markIfFirst() {
          DispatchQueue.main.async {
            onURL(url)
          }
        }
      }
    }

    process.terminationHandler = { proc in
      DispatchQueue.main.async {
        if proc.terminationStatus != 0 {
          onError("ngrok exited with status \(proc.terminationStatus)")
        }
      }
    }

    do {
      try process.run()
      self.process = process
      discoverURLFromLocalAPI(onURL: onURL)
    } catch {
      throw TunnelError.launchFailed(error.localizedDescription)
    }
  }

  func stop() {
    discoveryWorkItem?.cancel()
    discoveryWorkItem = nil
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    process?.terminate()
    process = nil
  }

  private func findNgrokBinary() -> String? {
    if let configured = config.ngrokBinary, FileManager.default.isExecutableFile(atPath: configured) {
      return configured
    }

    for candidate in [
      "/opt/homebrew/bin/ngrok",
      "/usr/local/bin/ngrok",
      "/usr/bin/ngrok",
    ] where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }

    return nil
  }

  private func discoverURLFromLocalAPI(onURL: @escaping @Sendable (String) -> Void) {
    let work = DispatchWorkItem {
      for _ in 0..<30 {
        if let url = Self.fetchTunnelURLFromLocalAPI() {
          DispatchQueue.main.async {
            onURL(url)
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.5)
      }
    }

    discoveryWorkItem = work
    DispatchQueue.global(qos: .utility).async(execute: work)
  }

  static func fetchTunnelURLFromLocalAPI() -> String? {
    guard let url = URL(string: "http://127.0.0.1:4040/api/tunnels") else {
      return nil
    }

    guard let data = try? Data(contentsOf: url) else {
      return nil
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tunnels = object["tunnels"] as? [[String: Any]]
    else {
      return nil
    }

    return tunnels.compactMap { tunnel in
      tunnel["public_url"] as? String
    }.first { $0.hasPrefix("https://") }
  }

  private static func extractURL(from line: String) -> String? {
    if
      let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let url = object["url"] as? String,
      url.hasPrefix("https://")
    {
      return url
    }

    if let range = line.range(of: #"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#, options: .regularExpression) {
      return String(line[range])
    }

    return nil
  }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false

  func markIfFirst() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if used { return false }
    used = true
    return true
  }
}
