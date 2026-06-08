import Foundation

final class Typist: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "mac2and.typist")
  private var running = false
  private var process: Process?
  private let chunkSize = 300
  private let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mac2and_type.applescript")

  var isTyping: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  func start(text: String) {
    stop()
    guard !text.isEmpty else { return }

    lock.lock()
    running = true
    lock.unlock()

    let chars = Array(text)
    queue.async { [weak self] in
      guard let self else { return }
      var offset = 0
      while self.isTyping && offset < chars.count {
        let end = min(offset + self.chunkSize, chars.count)
        let chunk = Array(chars[offset..<end])
        do {
          try self.runChunk(chunk)
        } catch {
          NSLog("[typist] osascript failed: \(error)")
          break
        }
        offset = end
      }

      self.lock.lock()
      self.running = false
      self.process = nil
      self.lock.unlock()
    }
  }

  func stop() {
    lock.lock()
    running = false
    let current = process
    process = nil
    lock.unlock()
    current?.terminate()
  }

  private func runChunk(_ chars: [Character]) throws {
    let script = buildScript(chars)
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [scriptURL.path]

    lock.lock()
    if !running {
      lock.unlock()
      return
    }
    self.process = process
    lock.unlock()

    try process.run()
    process.waitUntilExit()
  }

  private func buildScript(_ chars: [Character]) -> String {
    var lines = ["tell application \"System Events\""]
    for ch in chars {
      lines.append("  \(charToScript(ch))")
      lines.append("  delay \(String(format: "%.3f", humanDelay(ch)))")
    }
    lines.append("end tell")
    return lines.joined(separator: "\n")
  }

  private func charToScript(_ ch: Character) -> String {
    let scalar = ch.unicodeScalars.first?.value ?? 0
    if ch == "\n" || ch == "\r" { return "key code 36" }
    if ch == "\t" { return "key code 48" }
    if scalar == 34 || scalar < 32 || scalar > 126 {
      return "keystroke (character id \(scalar))"
    }
    return "keystroke \"\(ch)\""
  }

  private func humanDelay(_ ch: Character) -> Double {
    let punctuation = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ".,;:!?"))
    let scalar = ch.unicodeScalars.first ?? " "
    let base = punctuation.contains(scalar) ? 0.22 : 0.15
    let jitter = Double.random(in: -0.05...0.05)
    return max(0.08, base + jitter)
  }
}
