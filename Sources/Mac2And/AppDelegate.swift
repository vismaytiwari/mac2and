import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var config: AppConfig!
  private let state = AppState()
  private let typist = Typist()
  private var server: HTTPServer?
  private var clipboardWatcher: ClipboardWatcher?
  private var tunnel: NgrokTunnel?
  private var statusMenu: StatusMenuController?
  private var qrWindow: QRWindowController?
  private var refreshTimer: Timer?
  private var localURL: URL?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    config = AppConfig.load()
    requestNotificationPermission()

    do {
      let httpServer = HTTPServer(state: state, config: config, typist: typist)
      let port = try httpServer.start()
      server = httpServer
      localURL = URL(string: "http://127.0.0.1:\(port)")
      NSLog("[main] HTTP server listening on \(localURL?.absoluteString ?? "unknown")")
    } catch {
      showNotification(title: "Mac2And failed to start", body: "Could not start the local HTTP server.")
      NSLog("[main] Failed to start HTTP server: \(error)")
      NSApp.terminate(nil)
      return
    }

    clipboardWatcher = ClipboardWatcher(state: state, config: config)
    clipboardWatcher?.start()

    statusMenu = StatusMenuController(
      state: state,
      currentURL: { [weak self] in self?.currentURL },
      showQR: { [weak self] in self?.showQR() },
      copyURL: { [weak self] in self?.copyCurrentURL() },
      openURL: { [weak self] in self?.openCurrentURL() },
      togglePause: { [weak self] in self?.togglePause() },
      clearClipboardCache: { [weak self] in self?.clearClipboardCache() },
      quit: { NSApp.terminate(nil) }
    )

    startNgrok()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.statusMenu?.refresh()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    refreshTimer?.invalidate()
    clipboardWatcher?.stop()
    typist.stop()
    tunnel?.stop()
    server?.stop()
  }

  private var currentURL: URL? {
    if let publicUrl = state.snapshot().publicURL {
      return URL(string: publicUrl)
    }
    return localURL
  }

  private func startNgrok() {
    guard let port = server?.port else { return }

    do {
      let ngrok = try NgrokTunnel(config: config)
      tunnel = ngrok
      try ngrok.start(
        port: port,
        onURL: { [weak self] url in
          Task { @MainActor in
            self?.state.setTunnelURL(url)
            self?.statusMenu?.refresh()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            self?.showNotification(
              title: "Mac2And is running",
              body: "Android URL copied to clipboard."
            )
            self?.showQR()
          }
        },
        onError: { [weak self] message in
          Task { @MainActor in
            self?.state.setTunnelError(message)
            self?.statusMenu?.refresh()
            self?.showNotification(title: "Mac2And ngrok error", body: message)
          }
        }
      )
    } catch {
      let message = String(describing: error)
      state.setTunnelError(message)
      statusMenu?.refresh()
      showNotification(title: "Mac2And ngrok error", body: message)
    }
  }

  private func showQR() {
    guard let url = currentURL?.absoluteString else { return }
    if qrWindow == nil {
      qrWindow = QRWindowController()
    }
    qrWindow?.show(url: url)
  }

  private func copyCurrentURL() {
    guard let url = currentURL?.absoluteString else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
  }

  private func openCurrentURL() {
    guard let url = currentURL else { return }
    NSWorkspace.shared.open(url)
  }

  private func togglePause() {
    state.setSyncPaused(!state.snapshot().syncPaused)
    statusMenu?.refresh()
  }

  private func clearClipboardCache() {
    state.clearMacClipboardCache()
    statusMenu?.refresh()
  }

  private func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private func showNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}
