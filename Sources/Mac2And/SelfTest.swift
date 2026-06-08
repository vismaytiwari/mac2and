import Foundation

enum SelfTest {
  static func run() {
    do {
      let payload = try CryptoBox.encrypt("hello from swift", password: "secret")
      precondition(!payload.data.isEmpty, "encrypted data should not be empty")
      precondition(!payload.iv.isEmpty, "iv should not be empty")

      let decrypted = try CryptoBox.decrypt(payload, password: "secret")
      precondition(decrypted == "hello from swift", "crypto round trip failed")
      try runEnvDiscoveryTest()
      try runNgrokAPIParsingTest()

      do {
        _ = try CryptoBox.decrypt(payload, password: "wrong")
        fatalError("wrong password should fail")
      } catch {
        // expected
      }

      try runHTTPServerSmokeTest()

      print("Self-test passed")
    } catch {
      fatalError("Self-test failed: \(error)")
    }
  }

  private static func runHTTPServerSmokeTest() throws {
    let config = AppConfig(
      authToken: "selftest-token",
      appPassword: "selftest-password",
      ngrokAuthToken: nil,
      ngrokDomain: nil,
      ngrokBinary: nil,
      envFile: nil,
      serverPort: 0,
      clipboardPollSeconds: 2,
      maxClipSizeBytes: 500 * 1024
    )
    let state = AppState()
    let server = HTTPServer(state: state, config: config, typist: Typist())
    let port = try server.start()
    defer { server.stop() }

    let (data, statusCode) = try curl(
      url: "http://127.0.0.1:\(port)/api/latest",
      bearerToken: "selftest-password"
    )

    guard statusCode == 200 else {
      let body = String(decoding: data, as: UTF8.self)
      fatalError("HTTP smoke test returned \(statusCode): \(body)")
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    precondition(object?["ok"] as? Bool == true, "HTTP smoke response was not ok")
  }

  private static func runEnvDiscoveryTest() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mac2and-env-selftest-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    let app = dist.appendingPathComponent("Mac2And.app", isDirectory: true)

    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try "NGROK_AUTHTOKEN=test-token\nAPP_PASSWORD=test-password\n"
      .write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = EnvFile.resolvePath(
      explicit: nil,
      currentDirectory: "/",
      bundleURL: app,
      executablePath: nil
    )

    precondition(resolved == root.appendingPathComponent(".env").path, "bundle-relative .env discovery failed")
  }

  private static func runNgrokAPIParsingTest() throws {
    let sample = """
    {"tunnels":[{"name":"command_line","public_url":"https://example.ngrok-free.app","proto":"https","config":{"addr":"http://127.0.0.1:54321"}}]}
    """
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("mac2and-ngrok-selftest-\(UUID().uuidString).json")
    try sample.write(to: temp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let data = try Data(contentsOf: temp)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let tunnels = object?["tunnels"] as? [[String: Any]]
    let url = tunnels?.compactMap { $0["public_url"] as? String }.first { $0.hasPrefix("https://") }
    precondition(url == "https://example.ngrok-free.app", "ngrok API parsing failed")
  }

  private static func curl(url: String, bearerToken: String) throws -> (Data, Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
      "--max-time", "5",
      "-sS",
      "-H", "Authorization: Bearer \(bearerToken)",
      "-w", "\n%{http_code}",
      url,
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let statusPart = parts.last, let status = Int(statusPart) else {
      throw NSError(domain: "Mac2And.SelfTest", code: 2)
    }

    let body = parts.dropLast().joined(separator: "\n")
    return (Data(body.utf8), status)
  }
}
