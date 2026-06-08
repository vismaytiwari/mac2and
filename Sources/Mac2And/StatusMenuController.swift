import AppKit
import Foundation

@MainActor
final class StatusMenuController: NSObject {
  private let item: NSStatusItem
  private let state: AppState
  private let currentURL: () -> URL?
  private let showQR: () -> Void
  private let copyURL: () -> Void
  private let openURL: () -> Void
  private let togglePause: () -> Void
  private let clearClipboardCache: () -> Void
  private let quit: () -> Void

  init(
    state: AppState,
    currentURL: @escaping () -> URL?,
    showQR: @escaping () -> Void,
    copyURL: @escaping () -> Void,
    openURL: @escaping () -> Void,
    togglePause: @escaping () -> Void,
    clearClipboardCache: @escaping () -> Void,
    quit: @escaping () -> Void
  ) {
    self.state = state
    self.currentURL = currentURL
    self.showQR = showQR
    self.copyURL = copyURL
    self.openURL = openURL
    self.togglePause = togglePause
    self.clearClipboardCache = clearClipboardCache
    self.quit = quit
    self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    if let image = NSImage(named: "trayIconTemplate") ?? resourceImage("trayIconTemplate", "png") {
      image.isTemplate = true
      item.button?.image = image
    } else {
      item.button?.title = "M2A"
    }

    refresh()
  }

  func refresh() {
    item.menu = makeMenu()
  }

  private func makeMenu() -> NSMenu {
    let snapshot = state.snapshot()
    let menu = NSMenu()

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

    let pauseTitle = snapshot.syncPaused ? "Resume Clipboard Sync" : "Pause Clipboard Sync"
    menu.addItem(item(pauseTitle, action: #selector(onTogglePause)))
    menu.addItem(item("Clear Clipboard Cache", action: #selector(onClearClipboardCache)))
    menu.addItem(.separator())
    menu.addItem(item("Quit Mac2And", action: #selector(onQuit)))
    return menu
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

  @objc private func onShowQR() { showQR() }
  @objc private func onCopyURL() { copyURL() }
  @objc private func onOpenURL() { openURL() }
  @objc private func onTogglePause() { togglePause() }
  @objc private func onClearClipboardCache() { clearClipboardCache() }
  @objc private func onQuit() { quit() }
}
