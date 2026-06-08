import AppKit
import Foundation

final class ClipboardWatcher {
  private let state: AppState
  private let config: AppConfig
  private var timer: DispatchSourceTimer?

  init(state: AppState, config: AppConfig) {
    self.state = state
    self.config = config
  }

  func start() {
    if timer != nil { return }

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + config.clipboardPollSeconds,
      repeating: config.clipboardPollSeconds
    )
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func poll() {
    let snapshot = state.snapshot()
    if snapshot.syncPaused { return }

    let text = DispatchQueue.main.sync {
      NSPasteboard.general.string(forType: .string)
    }

    guard let text, !text.isEmpty else { return }
    if text.utf8.count > config.maxClipSizeBytes { return }
    if text != snapshot.lastSeenLocalClip {
      NSLog("[clipboard] New Mac clipboard detected (\(text.utf8.count) bytes)")
      state.updateMacClipboard(text)
    }
  }
}
