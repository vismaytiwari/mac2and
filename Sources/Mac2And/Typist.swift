import ApplicationServices
import CoreGraphics
import Foundation

/// Types text into the frontmost app by posting native key events.
///
/// We post `CGEvent` keystrokes directly instead of driving System Events via
/// osascript. That needs only one permission — Accessibility — attributed to
/// this app, and lets us pace each keystroke in Swift.
final class Typist: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "mac2and.typist")
  private var running = false
  // Bumped on every start() and stop(). A run only clears `running` if its
  // token is still current, so a superseded run can't cancel a newer one.
  private var generation = 0

  // Timing model.
  //
  // A brisk developer peaks around ~150 WPM in bursts, i.e. ~0.08 s between
  // keys. We treat that as the SPEED CAP: no keystroke is ever faster than
  // `minDelay`, so the typing never looks inhumanly instant. Most characters
  // land in a fast-but-human band; spaces and sentence punctuation get a
  // slightly longer (also randomized) pause, the way a real typist drifts.
  private let minDelay = 0.08                                 // hard floor = fastest allowed
  private let letterDelay: ClosedRange<Double> = 0.08...0.17  // ~85–150 WPM
  private let pauseDelay: ClosedRange<Double> = 0.17...0.32   // after space / . , ; : ! ?

  var isTyping: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  /// Whether this app may post synthetic keystrokes right now.
  var hasAccessibility: Bool { AXIsProcessTrusted() }

  /// Returns the current Accessibility trust state. When `prompt` is true and
  /// the app is not yet trusted, macOS adds it to the Accessibility list and
  /// shows the system prompt so the user can grant access.
  @discardableResult
  func ensureAccessibility(prompt: Bool) -> Bool {
    if AXIsProcessTrusted() { return true }
    guard prompt else { return false }
    // The literal value of kAXTrustedCheckOptionPrompt; using the string
    // avoids the Unmanaged<CFString> import differences between SDKs.
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func start(text: String) {
    stop()
    guard !text.isEmpty else { return }

    lock.lock()
    generation &+= 1
    let token = generation
    running = true
    lock.unlock()

    let chars = Array(text)
    queue.async { [weak self] in
      guard let self else { return }
      let source = CGEventSource(stateID: .hidSystemState)
      for ch in chars {
        if !self.isActive(token) { break }
        self.postCharacter(ch, source: source)
        self.sleepCancellably(self.humanDelay(ch), token: token)
      }
      self.lock.lock()
      if self.generation == token { self.running = false }
      self.lock.unlock()
    }
  }

  func stop() {
    lock.lock()
    running = false
    generation &+= 1
    lock.unlock()
  }

  /// True only while `token` is the live run (not stopped, not superseded).
  private func isActive(_ token: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return running && generation == token
  }

  /// Sleeps for `seconds`, waking early in small slices if the run is stopped
  /// so an in-flight type can be cancelled promptly.
  private func sleepCancellably(_ seconds: Double, token: Int) {
    var remaining = seconds
    while remaining > 0 && isActive(token) {
      let slice = min(remaining, 0.05)
      Thread.sleep(forTimeInterval: slice)
      remaining -= slice
    }
  }

  private func postCharacter(_ ch: Character, source: CGEventSource?) {
    // Send Return and Tab as real key codes so they act as Enter / Tab.
    if ch == "\n" || ch == "\r" { postKeyCode(36, source: source); return }
    if ch == "\t" { postKeyCode(48, source: source); return }

    // Inject the literal character (covering uppercase, symbols, emoji, and
    // composed graphemes) without simulating modifier keys or guessing layout.
    var utf16 = Array(String(ch).utf16)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { return }
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  private func postKeyCode(_ key: CGKeyCode, source: CGEventSource?) {
    CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
  }

  private func humanDelay(_ ch: Character) -> Double {
    let pausers = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ".,;:!?"))
    let scalar = ch.unicodeScalars.first ?? " "
    let delay = pausers.contains(scalar)
      ? Double.random(in: pauseDelay)
      : Double.random(in: letterDelay)
    return max(minDelay, delay)
  }
}
