import AppKit
import Foundation
import Security
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let passwordAccount = "app-password"

  private var config: AppConfig!
  private let state = AppState()
  private let typist = Typist()
  private var server: HTTPServer?
  private var clipboardWatcher: ClipboardWatcher?
  private var tunnel: NgrokTunnel?
  private var statusMenu: StatusMenuController?
  private var qrWindow: QRWindowController?
  private var localURL: URL?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Regular (Dock) app so it shows in the Dock, ⌘-Tab, and the Force Quit
    // window — even when the menu-bar icon is hidden.
    NSApp.setActivationPolicy(.regular)
    setupMainMenu()

    config = AppConfig.load()
    state.setPassword(resolveInitialPassword())
    requestNotificationPermission()
    warnIfWeakPassword()

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

    if !typist.hasAccessibility {
      NSLog("[main] Accessibility not granted; Slow Type will prompt on first use.")
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
      toggleRemoteTyping: { [weak self] in self?.toggleRemoteTyping() },
      clearClipboardCache: { [weak self] in self?.clearClipboardCache() },
      changePassword: { [weak self] in self?.changePassword() },
      purge: { [weak self] in self?.purge() },
      blockDevice: { [weak self] id in self?.blockDevice(id) },
      unblockDevice: { [weak self] id in self?.unblockDevice(id) },
      quit: { NSApp.terminate(nil) }
    )

    startNgrok()
  }

  func applicationWillTerminate(_ notification: Notification) {
    clipboardWatcher?.stop()
    typist.stop()
    tunnel?.stop()
    server?.stop()
  }

  // Clicking the Dock icon (or relaunching) brings a hidden menu-bar icon back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    statusMenu?.showIcon()
    return true
  }

  private func setupMainMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide Mac2And", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Mac2And", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    NSApp.mainMenu = mainMenu
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
      let controller = QRWindowController()
      // Drop our reference once the window closes so it (and the CoreImage
      // memory used to render the QR) is reclaimed. Deferred so we don't
      // deallocate the controller while it is still handling the close.
      controller.onClose = { [weak self] in
        DispatchQueue.main.async { self?.qrWindow = nil }
      }
      qrWindow = controller
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

  private func toggleRemoteTyping() {
    let enabling = !state.snapshot().remoteTypingEnabled
    state.setRemoteTypingEnabled(enabling)
    if !enabling { typist.stop() }
    statusMenu?.refresh()
  }

  private func clearClipboardCache() {
    state.clearMacClipboardCache()
    statusMenu?.refresh()
  }

  private func blockDevice(_ id: String) {
    state.blockDevice(id: id, for: 3600)
    statusMenu?.refresh()
  }

  private func unblockDevice(_ id: String) {
    state.unblockDevice(id: id)
    statusMenu?.refresh()
  }

  private func changePassword() {
    let alert = NSAlert()
    alert.messageText = "Change Mac2And Password"
    alert.informativeText = "Devices must reconnect with the new password. This also rotates the clipboard encryption key, so the old password immediately stops working."
    alert.addButton(withTitle: "Change")
    alert.addButton(withTitle: "Cancel")

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = "New password"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let newPassword = field.stringValue
    guard !newPassword.isEmpty else { return }

    state.setPassword(newPassword)
    if !Keychain.set(newPassword, account: Self.passwordAccount) {
      NSLog("[security] Could not persist password to Keychain; it will revert on relaunch.")
    }
    statusMenu?.refresh()
    showNotification(title: "Password changed", body: "Reconnect your devices with the new password.")
    if Self.isWeakPassword(newPassword) {
      NSLog("[security] The new password is weak; consider a longer, more varied value.")
    }
  }

  /// Panic button: disconnect everyone, forget the connection list and
  /// rate-limit state, and lock with a fresh random password the user does not
  /// know — so they must set a new one via "Change Password…" before any device
  /// can reconnect. Clipboard history is intentionally preserved.
  private func purge() {
    let alert = NSAlert()
    alert.messageText = "Purge Mac2And?"
    alert.informativeText = "Disconnects all devices, clears the connection list, and locks with a new random password. You must set a known password via “Change Password…” before any device can reconnect. Your clipboard history is kept."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Purge")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let random = Self.randomPassword()
    state.setPassword(random)
    if !Keychain.set(random, account: Self.passwordAccount) {
      NSLog("[security] Purge could not persist the random password to Keychain.")
    }
    state.clearDevices()
    server?.resetThrottle()
    statusMenu?.refresh()
    showNotification(
      title: "Mac2And purged",
      body: "All devices disconnected. Set a new password (Change Password…) to reconnect."
    )
  }

  private static func randomPassword() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      return UUID().uuidString + UUID().uuidString
    }
    return Data(bytes).base64EncodedString()
  }

  /// Effective password at launch: a previously set Keychain value wins, then
  /// the bootstrap `.env` APP_PASSWORD, then a random token (page unreachable
  /// remotely until a password is set).
  private func resolveInitialPassword() -> String {
    if let stored = Keychain.get(Self.passwordAccount), !stored.isEmpty { return stored }
    if let envPassword = config.appPassword, !envPassword.isEmpty { return envPassword }
    return config.authToken
  }

  // The page and API are reachable over the public ngrok URL, so a weak
  // password is the main brute-force risk. (With no password set, the app uses
  // a random 128-bit token instead, which is strong.)
  private func warnIfWeakPassword() {
    guard Self.isWeakPassword(state.currentPassword()) else { return }
    NSLog("[security] The Mac2And password is weak — clipboard sync and remote typing are exposed over your public ngrok URL.")
    showNotification(
      title: "Mac2And: weak password",
      body: "Your password is weak. Use “Change Password…” in the menu bar to set a long, random value."
    )
  }

  private static func isWeakPassword(_ password: String) -> Bool {
    if password.count < 12 { return true }
    let classes = [
      password.contains { $0.isLowercase },
      password.contains { $0.isUppercase },
      password.contains { $0.isNumber },
      password.contains { !$0.isLetter && !$0.isNumber },
    ].filter { $0 }.count
    return classes < 2
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
