import AppKit
import Foundation

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
  private let item: NSStatusItem
  private let menu = NSMenu()
  private let state: AppState
  private let currentURL: () -> URL?
  private let showQR: () -> Void
  private let copyURL: () -> Void
  private let openURL: () -> Void
  private let togglePause: () -> Void
  private let toggleRemoteTyping: () -> Void
  private let clearClipboardCache: () -> Void
  private let changePassword: () -> Void
  private let purge: () -> Void
  private let blockDevice: (String) -> Void
  private let unblockDevice: (String) -> Void
  private let quit: () -> Void

  init(
    state: AppState,
    currentURL: @escaping () -> URL?,
    showQR: @escaping () -> Void,
    copyURL: @escaping () -> Void,
    openURL: @escaping () -> Void,
    togglePause: @escaping () -> Void,
    toggleRemoteTyping: @escaping () -> Void,
    clearClipboardCache: @escaping () -> Void,
    changePassword: @escaping () -> Void,
    purge: @escaping () -> Void,
    blockDevice: @escaping (String) -> Void,
    unblockDevice: @escaping (String) -> Void,
    quit: @escaping () -> Void
  ) {
    self.state = state
    self.currentURL = currentURL
    self.showQR = showQR
    self.copyURL = copyURL
    self.openURL = openURL
    self.togglePause = togglePause
    self.toggleRemoteTyping = toggleRemoteTyping
    self.clearClipboardCache = clearClipboardCache
    self.changePassword = changePassword
    self.purge = purge
    self.blockDevice = blockDevice
    self.unblockDevice = unblockDevice
    self.quit = quit
    self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    if let image = NSImage(named: "trayIconTemplate") ?? resourceImage("trayIconTemplate", "png") {
      image.isTemplate = true
      item.button?.image = image
    } else {
      item.button?.title = "M2A"
    }

    menu.delegate = self
    item.menu = menu
    rebuild()
  }

  // The menu is rebuilt only when it is about to open (or when state changes),
  // not on a timer — it has no time-based content, so periodic refresh is waste.
  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuild()
  }

  func refresh() {
    rebuild()
  }

  /// Re-shows a hidden menu-bar icon (called when the app is reopened).
  func showIcon() {
    item.isVisible = true
  }

  private func rebuild() {
    let snapshot = state.snapshot()
    menu.removeAllItems()

    let statusText: String
    if let publicURL = snapshot.publicURL {
      statusText = "Running: \(publicURL)"
    } else if let error = snapshot.tunnelError {
      statusText = "Local only: \(error)"
    } else {
      statusText = "Starting..."
    }

    let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())

    menu.addItem(item("Show QR Code", action: #selector(onShowQR)))
    menu.addItem(item("Copy Android URL", action: #selector(onCopyURL)))
    menu.addItem(item("Open Android Page", action: #selector(onOpenURL)))
    menu.addItem(.separator())

    addDevicesItem(to: menu, devices: snapshot.devices)
    menu.addItem(.separator())

    let pauseTitle = snapshot.syncPaused ? "Resume Clipboard Sync" : "Pause Clipboard Sync"
    menu.addItem(item(pauseTitle, action: #selector(onTogglePause)))

    let typingTitle = snapshot.remoteTypingEnabled ? "Disable Remote Typing" : "Enable Remote Typing"
    let typingItem = item(typingTitle, action: #selector(onToggleRemoteTyping))
    typingItem.state = snapshot.remoteTypingEnabled ? .on : .off
    menu.addItem(typingItem)

    menu.addItem(item("Change Password…", action: #selector(onChangePassword)))
    menu.addItem(item("Purge…", action: #selector(onPurge)))
    menu.addItem(item("Clear Clipboard Cache", action: #selector(onClearClipboardCache)))
    menu.addItem(.separator())
    menu.addItem(item("Hide Menu Bar Icon", action: #selector(onHideIcon)))
    menu.addItem(item("Quit Mac2And", action: #selector(onQuit)))
  }

  private func addDevicesItem(to menu: NSMenu, devices: [DeviceSnapshot]) {
    let header = NSMenuItem(title: "Connected Devices", action: nil, keyEquivalent: "")
    let submenu = NSMenu()

    if devices.isEmpty {
      let empty = NSMenuItem(title: "No recent devices", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      submenu.addItem(empty)
    } else {
      for device in devices {
        let blocked = device.blockedUntil != nil
        // A header-less stream (e.g. a stale tab from before device ids) was
        // stored under the IP, so id == ip — flag it instead of showing a
        // meaningless suffix. Otherwise show a short id so sessions are distinct.
        let marker = device.id == device.ip
          ? "older tab"
          : "#" + String(device.id.replacingOccurrences(of: "-", with: "").suffix(4))
        let title = "\(Self.label(for: device.userAgent)) · \(device.ip) · \(marker) · \(Self.ago(device.lastSeen))"
        let deviceItem = NSMenuItem(title: blocked ? "🚫 \(title)" : title, action: nil, keyEquivalent: "")

        let actions = NSMenu()
        if blocked {
          let unblock = item("Unblock", action: #selector(onUnblockDevice))
          unblock.representedObject = device.id
          actions.addItem(unblock)
        } else {
          let block = item("Block for 1 hour", action: #selector(onBlockDevice))
          block.representedObject = device.id
          actions.addItem(block)
        }
        deviceItem.submenu = actions
        submenu.addItem(deviceItem)
      }
    }

    header.submenu = submenu
    menu.addItem(header)
  }

  private func item(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func resourceImage(_ name: String, _ ext: String) -> NSImage? {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }

  private static func label(for userAgent: String) -> String {
    if userAgent.contains("iPhone") { return "iPhone" }
    if userAgent.contains("iPad") { return "iPad" }
    if userAgent.contains("Android") { return "Android" }
    if userAgent.contains("Macintosh") { return "Mac" }
    if userAgent.contains("Windows") { return "Windows" }
    if userAgent.isEmpty { return "Device" }
    return "Browser"
  }

  private static func ago(_ date: Date) -> String {
    let seconds = Int(max(0, Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    return "\(seconds / 60)m ago"
  }

  @objc private func onShowQR() { showQR() }
  @objc private func onCopyURL() { copyURL() }
  @objc private func onOpenURL() { openURL() }
  @objc private func onTogglePause() { togglePause() }
  @objc private func onToggleRemoteTyping() { toggleRemoteTyping() }
  @objc private func onChangePassword() { changePassword() }
  @objc private func onPurge() { purge() }
  @objc private func onClearClipboardCache() { clearClipboardCache() }
  @objc private func onHideIcon() { item.isVisible = false }
  @objc private func onBlockDevice(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { blockDevice(id) }
  }
  @objc private func onUnblockDevice(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { unblockDevice(id) }
  }
  @objc private func onQuit() { quit() }
}
