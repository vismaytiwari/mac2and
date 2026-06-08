import AppKit
import CryptoKit
import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
  private let state: AppState
  private let config: AppConfig
  private let typist: Typist
  private let throttle = AuthThrottle()
  private let queue = DispatchQueue(label: "mac2and.http")
  private var listener: NWListener?
  private(set) var port: UInt16 = 0

  init(state: AppState, config: AppConfig, typist: Typist) {
    self.state = state
    self.config = config
    self.typist = typist
  }

  func start() throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let requestedPort = config.serverPort == 0
      ? NWEndpoint.Port.any
      : NWEndpoint.Port(rawValue: config.serverPort)!
    let listener = try NWListener(using: parameters, on: requestedPort)
    self.listener = listener

    let ready = DispatchSemaphore(value: 0)
    let startupState = StartupState()

    listener.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case .ready:
        self?.port = listener.port?.rawValue ?? self?.config.serverPort ?? 0
        ready.signal()
      case .failed(let error):
        startupState.set(error)
        ready.signal()
      default:
        break
      }
    }

    listener.newConnectionHandler = { [weak self] connection in
      self?.receive(connection: connection)
    }
    listener.start(queue: queue)

    _ = ready.wait(timeout: .now() + 5)
    if let startupError = startupState.error { throw startupError }
    if port == 0 { throw NSError(domain: "Mac2And.HTTP", code: 1) }
    return port
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  /// Clears the failed-auth rate-limit state (used by Purge).
  func resetThrottle() {
    throttle.reset()
  }

  private func receive(connection: NWConnection) {
    connection.start(queue: queue)
    read(connection: connection, buffer: Data())
  }

  private func read(connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        return
      }

      var next = buffer
      if let data { next.append(data) }

      if let request = HTTPRequest.parse(data: next) {
        let response = self.handle(request, remote: connection.endpoint)
        connection.send(content: response.data, completion: .contentProcessed { _ in
          connection.cancel()
        })
        return
      }

      if isComplete || next.count > 700 * 1024 {
        let response = HTTPResponse.json(status: 400, object: ["ok": false, "error": "Bad request"])
        connection.send(content: response.data, completion: .contentProcessed { _ in
          connection.cancel()
        })
        return
      }

      self.read(connection: connection, buffer: next)
    }
  }

  private func handle(_ request: HTTPRequest, remote: NWEndpoint) -> HTTPResponse {
    let path = request.path.components(separatedBy: "?").first ?? request.path

    switch (request.method, path) {
    case ("GET", "/"):
      return fileResponse(resource: "android", ext: "html", contentType: "text/html; charset=utf-8")
    case ("GET", "/manifest.json"):
      return HTTPResponse.json(status: 200, object: manifest())
    case ("GET", "/icon-192.png"):
      return fileResponse(resource: "icon", ext: "png", contentType: "image/png")
    case ("GET", "/sw.js"):
      return HTTPResponse.text(status: 200, text: serviceWorker, contentType: "application/javascript")
    case ("GET", "/api/latest"):
      return authenticated(request: request, remote: remote) {
        latestResponse()
      }
    case ("GET", "/api/history"):
      return authenticated(request: request, remote: remote) {
        historyResponse()
      }
    case ("POST", "/api/send-to-mac"):
      return authenticated(request: request, remote: remote) {
        sendToMacResponse(request)
      }
    case ("POST", "/api/type"):
      return authenticated(request: request, remote: remote) {
        typeResponse(request)
      }
    default:
      return HTTPResponse.json(status: 404, object: ["ok": false, "error": "Not found"])
    }
  }

  private func authenticated(
    request: HTTPRequest,
    remote: NWEndpoint,
    handler: () -> HTTPResponse
  ) -> HTTPResponse {
    // The API is reachable over the public ngrok URL, so throttle brute force.
    // The limit is global because over the tunnel we can't trust a per-client
    // identity (X-Forwarded-For is client-spoofable).
    if throttle.isLocked() {
      return HTTPResponse.json(status: 429, object: ["ok": false, "error": "Too many attempts. Try again shortly."])
    }

    guard Self.constantTimeEquals(request.bearerToken, state.currentPassword()) else {
      throttle.recordFailure()
      return HTTPResponse.json(status: 400, object: ["ok": false, "error": "Disconnected"])
    }
    throttle.recordSuccess()

    let ip = request.forwardedFor ?? String(describing: remote)
    let deviceID = request.deviceId ?? ip
    state.recordDevice(id: deviceID, ip: ip, userAgent: request.userAgent ?? "")
    if state.isBlocked(id: deviceID) {
      return HTTPResponse.json(status: 403, object: ["ok": false, "blocked": true, "error": "This device is blocked from the Mac."])
    }

    return handler()
  }

  /// Compares two secrets without leaking length or position of the first
  /// difference: both are hashed to a fixed 32 bytes, then XOR-accumulated.
  private static func constantTimeEquals(_ provided: String?, _ expected: String) -> Bool {
    guard let provided else { return false }
    let a = Data(SHA256.hash(data: Data(provided.utf8)))
    let b = Data(SHA256.hash(data: Data(expected.utf8)))
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
  }

  private func latestResponse() -> HTTPResponse {
    let snapshot = state.snapshot()
    let hasMacContent = !snapshot.latestMacClip.isEmpty && snapshot.lastUpdateSource == "mac"
    let payload = hasMacContent
      ? try? CryptoBox.encrypt(snapshot.latestMacClip, password: state.currentPassword())
      : nil

    return HTTPResponse.json(status: 200, object: [
      "ok": true,
      "payload": payload.map(payloadObject) as Any? ?? NSNull(),
      "updatedAt": snapshot.latestUpdatedAt as Any? ?? NSNull(),
      "source": snapshot.lastUpdateSource as Any? ?? NSNull(),
    ])
  }

  private func historyResponse() -> HTTPResponse {
    let snapshot = state.snapshot()
    let password = state.currentPassword()
    let items = snapshot.macClipHistory.compactMap {
      try? CryptoBox.encrypt($0, password: password)
    }.map(payloadObject)

    return HTTPResponse.json(status: 200, object: [
      "ok": true,
      "items": items,
      "updatedAt": snapshot.latestUpdatedAt as Any? ?? NSNull(),
      "connectedCount": snapshot.connectedCount,
      "stats": [
        "rssMB": snapshot.lastStats.rssMB,
      ],
      "isTyping": typist.isTyping,
    ])
  }

  private func sendToMacResponse(_ request: HTTPRequest) -> HTTPResponse {
    guard
      let body = request.jsonBody as? [String: Any],
      let payloadObject = body["payload"] as? [String: Any],
      let data = payloadObject["data"] as? String,
      let iv = payloadObject["iv"] as? String
    else {
      return HTTPResponse.json(
        status: 400,
        object: ["ok": false, "error": "\"payload\" must be an object with \"data\" and \"iv\" string fields"]
      )
    }

    let payload = EncryptedPayload(data: data, iv: iv)
    let text: String
    do {
      text = try CryptoBox.decrypt(payload, password: state.currentPassword())
    } catch {
      return HTTPResponse.json(status: 400, object: ["ok": false, "error": "Decryption failed"])
    }

    if text.utf8.count > config.maxClipSizeBytes {
      return HTTPResponse.json(
        status: 413,
        object: ["ok": false, "error": "Text exceeds maximum allowed size of \(config.maxClipSizeBytes) bytes"]
      )
    }

    state.updateAndroidClipboard(text)
    DispatchQueue.main.async {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }

    return HTTPResponse.json(status: 200, object: ["ok": true])
  }

  private func typeResponse(_ request: HTTPRequest) -> HTTPResponse {
    guard
      let body = request.jsonBody as? [String: Any],
      let action = body["action"] as? String
    else {
      return HTTPResponse.json(status: 400, object: ["ok": false, "error": "action must be \"start\" or \"stop\""])
    }

    switch action {
    case "start":
      guard state.snapshot().remoteTypingEnabled else {
        return HTTPResponse.json(status: 200, object: [
          "ok": false,
          "isTyping": false,
          "error": "Remote typing is disabled. Enable it from the Mac2And menu bar icon, then try again.",
        ])
      }
      guard typist.ensureAccessibility(prompt: true) else {
        return HTTPResponse.json(status: 200, object: [
          "ok": false,
          "isTyping": false,
          "error": "Allow Mac2And under System Settings → Privacy & Security → Accessibility on the Mac, then try again.",
        ])
      }
      let clip = state.snapshot().latestMacClip
      guard !clip.isEmpty else {
        return HTTPResponse.json(status: 200, object: [
          "ok": false,
          "isTyping": false,
          "error": "Nothing to type — the Mac clipboard is empty.",
        ])
      }
      typist.start(text: clip)
    case "stop":
      typist.stop()
    default:
      return HTTPResponse.json(status: 400, object: ["ok": false, "error": "action must be \"start\" or \"stop\""])
    }

    return HTTPResponse.json(status: 200, object: ["ok": true, "isTyping": typist.isTyping])
  }

  private func fileResponse(resource: String, ext: String, contentType: String) -> HTTPResponse {
    guard let url = Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Resources") else {
      return HTTPResponse.json(status: 404, object: ["ok": false, "error": "Resource not found"])
    }

    do {
      return HTTPResponse(status: 200, contentType: contentType, body: try Data(contentsOf: url))
    } catch {
      return HTTPResponse.json(status: 500, object: ["ok": false, "error": "Resource read failed"])
    }
  }

  private func payloadObject(_ payload: EncryptedPayload) -> [String: String] {
    ["data": payload.data, "iv": payload.iv]
  }

  private func manifest() -> [String: Any] {
    [
      "name": "Mac Clipboard",
      "short_name": "Mac Clip",
      "description": "Sync clipboard between your Mac and Android",
      "start_url": "/",
      "display": "standalone",
      "background_color": "#0f172a",
      "theme_color": "#0f172a",
      "orientation": "portrait-primary",
      "icons": [
        ["src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"],
        ["src": "/icon-192.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"],
      ],
    ]
  }

  private var serviceWorker: String {
    """
    self.addEventListener('install', () => self.skipWaiting());
    self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
    self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));
    """
  }
}

private final class StartupState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Swift.Error?

  var error: Swift.Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  func set(_ error: Swift.Error) {
    lock.lock()
    storedError = error
    lock.unlock()
  }
}

/// Global sliding-window throttle for failed authentication. After
/// `maxFailures` bad tokens within `window`, all auth is locked out for
/// `lockout` seconds. Successful auth clears the window.
private final class AuthThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var failures: [Date] = []
  private var lockedUntil: Date?
  private let maxFailures: Int
  private let window: TimeInterval
  private let lockout: TimeInterval

  init(maxFailures: Int = 10, window: TimeInterval = 60, lockout: TimeInterval = 60) {
    self.maxFailures = maxFailures
    self.window = window
    self.lockout = lockout
  }

  func isLocked() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let until = lockedUntil {
      if Date() < until { return true }
      lockedUntil = nil
    }
    return false
  }

  func recordFailure() {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    failures.append(now)
    failures.removeAll { now.timeIntervalSince($0) > window }
    if failures.count >= maxFailures {
      lockedUntil = now.addingTimeInterval(lockout)
      failures.removeAll()
    }
  }

  func recordSuccess() {
    reset()
  }

  func reset() {
    lock.lock()
    failures.removeAll()
    lockedUntil = nil
    lock.unlock()
  }
}

struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  var bearerToken: String? {
    guard let auth = headers["authorization"], auth.hasPrefix("Bearer ") else {
      return nil
    }
    return String(auth.dropFirst("Bearer ".count))
  }

  var forwardedFor: String? {
    headers["x-forwarded-for"]?.split(separator: ",").first.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  var deviceId: String? {
    headers["x-device-id"].flatMap { $0.isEmpty ? nil : $0 }
  }

  var userAgent: String? {
    headers["user-agent"]
  }

  var jsonBody: Any? {
    try? JSONSerialization.jsonObject(with: body)
  }

  static func parse(data: Data) -> HTTPRequest? {
    let separator = Data("\r\n\r\n".utf8)
    guard let marker = data.range(of: separator) else {
      return nil
    }

    let headerData = data[..<marker.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      return nil
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      headers[key] = value
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = marker.upperBound
    guard data.count >= bodyStart + contentLength else {
      return nil
    }

    return HTTPRequest(
      method: String(requestParts[0]),
      path: String(requestParts[1]),
      headers: headers,
      body: data[bodyStart..<bodyStart + contentLength]
    )
  }
}

struct HTTPResponse {
  let status: Int
  let contentType: String
  let body: Data

  var data: Data {
    var response = Data()
    response.append("HTTP/1.1 \(status) \(reason)\r\n".data(using: .utf8)!)
    response.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!)
    response.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
    response.append("Connection: close\r\n".data(using: .utf8)!)
    response.append("Cache-Control: no-store\r\n\r\n".data(using: .utf8)!)
    response.append(body)
    return response
  }

  private var reason: String {
    switch status {
    case 200: "OK"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 413: "Payload Too Large"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    default: "OK"
    }
  }

  static func json(status: Int, object: Any) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    return HTTPResponse(status: status, contentType: "application/json", body: data)
  }

  static func text(status: Int, text: String, contentType: String) -> HTTPResponse {
    HTTPResponse(status: status, contentType: contentType, body: Data(text.utf8))
  }
}
