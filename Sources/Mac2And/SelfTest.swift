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
      try runAuthHardeningTest()
      try runDeviceAndPasswordTest()

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
    state.setPassword("selftest-password")
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

  private static func runAuthHardeningTest() throws {
    let token = "selftest-strong-Password-123!"
    let config = AppConfig(
      authToken: "selftest-token",
      appPassword: token,
      ngrokAuthToken: nil,
      ngrokDomain: nil,
      ngrokBinary: nil,
      envFile: nil,
      serverPort: 0,
      clipboardPollSeconds: 2,
      maxClipSizeBytes: 500 * 1024
    )
    let state = AppState()
    state.setPassword(token)
    let server = HTTPServer(state: state, config: config, typist: Typist())
    let port = try server.start()
    defer { server.stop() }
    let base = "http://127.0.0.1:\(port)"

    // Remote typing is OFF by default, so /api/type "start" must be refused
    // (ok:false) rather than begin typing. Correct token here also keeps the
    // throttle clear for the checks below.
    let (typeData, typeStatus) = try curl(
      url: "\(base)/api/type",
      bearerToken: token,
      method: "POST",
      body: "{\"action\":\"start\"}"
    )
    precondition(typeStatus == 200, "type endpoint returned \(typeStatus)")
    let typeObject = try JSONSerialization.jsonObject(with: typeData) as? [String: Any]
    precondition(typeObject?["ok"] as? Bool == false, "remote typing should be disabled by default")

    // A wrong token is rejected.
    let (_, wrongStatus) = try curl(url: "\(base)/api/latest", bearerToken: "wrong-token")
    precondition(wrongStatus == 400, "wrong token should be rejected, got \(wrongStatus)")

    // Repeated wrong tokens trip the global lockout (429).
    var sawLockout = false
    for _ in 0..<20 {
      let (_, status) = try curl(url: "\(base)/api/latest", bearerToken: "wrong-token")
      if status == 429 { sawLockout = true; break }
    }
    precondition(sawLockout, "rate limiting did not trigger after repeated failures")
  }

  private static func runDeviceAndPasswordTest() throws {
    let token = "selftest-device-Password-123!"
    let config = AppConfig(
      authToken: "selftest-token",
      appPassword: token,
      ngrokAuthToken: nil,
      ngrokDomain: nil,
      ngrokBinary: nil,
      envFile: nil,
      serverPort: 0,
      clipboardPollSeconds: 2,
      maxClipSizeBytes: 500 * 1024
    )
    let state = AppState()
    state.setPassword(token)
    let server = HTTPServer(state: state, config: config, typist: Typist())
    let port = try server.start()
    defer { server.stop() }
    let base = "http://127.0.0.1:\(port)"

    func get(_ device: String, token: String) throws -> Int {
      try curl(url: "\(base)/api/latest", bearerToken: token, headers: ["X-Device-Id: \(device)"]).1
    }

    // A correct token from a device works.
    let allowed = try get("dev-1", token: token)
    precondition(allowed == 200, "device dev-1 should be allowed, got \(allowed)")

    // Blocking dev-1 yields 403 even with the correct token; other devices are fine.
    state.blockDevice(id: "dev-1", for: 3600)
    let blocked = try get("dev-1", token: token)
    precondition(blocked == 403, "blocked device should get 403, got \(blocked)")
    let other = try get("dev-2", token: token)
    precondition(other == 200, "unblocked device should still work, got \(other)")

    // Unblocking restores access.
    state.unblockDevice(id: "dev-1")
    let restored = try get("dev-1", token: token)
    precondition(restored == 200, "unblocked device should work again, got \(restored)")

    // Changing the password revokes the old one and accepts the new one.
    state.setPassword("selftest-rotated-Password-456!")
    let oldRejected = try get("dev-2", token: token)
    precondition(oldRejected == 400, "old password should be rejected after change, got \(oldRejected)")
    let newAccepted = try get("dev-2", token: "selftest-rotated-Password-456!")
    precondition(newAccepted == 200, "new password should be accepted, got \(newAccepted)")
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

  private static func curl(
    url: String,
    bearerToken: String,
    method: String = "GET",
    body: String? = nil,
    headers: [String] = []
  ) throws -> (Data, Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = [
      "--max-time", "5",
      "-sS",
      "-X", method,
      "-H", "Authorization: Bearer \(bearerToken)",
    ]
    for header in headers { arguments += ["-H", header] }
    if let body {
      arguments += ["-H", "Content-Type: application/json", "--data", body]
    }
    arguments += ["-w", "\n%{http_code}", url]
    process.arguments = arguments

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
