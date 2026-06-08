import Foundation
import MachO

struct ProcessStats: Codable {
  let rssMB: Int
}

/// A connected device as shown in the menu bar.
struct DeviceSnapshot {
  let id: String
  let userAgent: String
  let ip: String
  let lastSeen: Date
  let blockedUntil: Date?
}

struct AppSnapshot {
  let latestMacClip: String
  let macClipHistory: [String]
  let connectedCount: Int
  let devices: [DeviceSnapshot]
  let lastStats: ProcessStats
  let lastSeenLocalClip: String
  let lastUpdateSource: String?
  let latestUpdatedAt: Int64?
  let syncPaused: Bool
  let remoteTypingEnabled: Bool
  let publicURL: String?
  let tunnelError: String?
}

final class AppState {
  private struct DeviceRecord {
    var ip: String
    var userAgent: String
    var lastSeen: Date
  }

  private let lock = NSLock()
  private var latestMacClip = ""
  private var macClipHistory: [String] = []
  private var devices: [String: DeviceRecord] = [:]
  private var blockedUntil: [String: Date] = [:]
  private var lastSeenLocalClip = ""
  private var lastUpdateSource: String?
  private var latestUpdatedAt: Int64?
  private var syncPaused = false
  // Remote typing (/api/type) is a high-risk capability — typing into the
  // focused Mac app from a request that arrives over the public tunnel. It is
  // OFF until explicitly enabled from the menu bar.
  private var remoteTypingEnabled = false
  // The effective auth secret (also derives the clipboard encryption key).
  // Set at launch and changeable from the menu bar; the menu/Keychain own
  // persistence, this is just the live value.
  private var password = ""
  private var publicURL: String?
  private var tunnelError: String?

  func snapshot() -> AppSnapshot {
    lock.lock()
    defer { lock.unlock() }
    pruneDevicesLocked()
    let recentCutoff = Date().addingTimeInterval(-60)
    return AppSnapshot(
      latestMacClip: latestMacClip,
      macClipHistory: macClipHistory,
      connectedCount: devices.values.filter { $0.lastSeen >= recentCutoff }.count,
      devices: recentDevicesLocked(),
      lastStats: Self.currentStats(),
      lastSeenLocalClip: lastSeenLocalClip,
      lastUpdateSource: lastUpdateSource,
      latestUpdatedAt: latestUpdatedAt,
      syncPaused: syncPaused,
      remoteTypingEnabled: remoteTypingEnabled,
      publicURL: publicURL,
      tunnelError: tunnelError
    )
  }

  func updateMacClipboard(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    latestMacClip = text
    lastSeenLocalClip = text
    lastUpdateSource = "mac"
    latestUpdatedAt = Self.nowMillis()
    macClipHistory = ([text] + macClipHistory.filter { $0 != text }).prefix(20).map { $0 }
  }

  func updateAndroidClipboard(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    latestMacClip = text
    lastSeenLocalClip = text
    lastUpdateSource = "android"
    latestUpdatedAt = Self.nowMillis()
  }

  func setSyncPaused(_ value: Bool) {
    lock.lock()
    syncPaused = value
    lock.unlock()
  }

  func setRemoteTypingEnabled(_ value: Bool) {
    lock.lock()
    remoteTypingEnabled = value
    lock.unlock()
  }

  func clearMacClipboardCache() {
    lock.lock()
    latestMacClip = ""
    lastUpdateSource = nil
    latestUpdatedAt = Self.nowMillis()
    lock.unlock()
  }

  // MARK: Auth secret

  func currentPassword() -> String {
    lock.lock()
    defer { lock.unlock() }
    return password
  }

  func setPassword(_ value: String) {
    lock.lock()
    password = value
    lock.unlock()
  }

  // MARK: Devices

  func recordDevice(id: String, ip: String, userAgent: String) {
    lock.lock()
    defer { lock.unlock() }
    devices[id] = DeviceRecord(ip: ip, userAgent: userAgent, lastSeen: Date())
    pruneDevicesLocked()
  }

  func isBlocked(id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let until = blockedUntil[id] else { return false }
    if until > Date() { return true }
    blockedUntil[id] = nil
    return false
  }

  func blockDevice(id: String, for duration: TimeInterval) {
    lock.lock()
    blockedUntil[id] = Date().addingTimeInterval(duration)
    lock.unlock()
  }

  func unblockDevice(id: String) {
    lock.lock()
    blockedUntil[id] = nil
    lock.unlock()
  }

  /// Forgets all known devices and blocks (clipboard state is untouched).
  func clearDevices() {
    lock.lock()
    devices.removeAll()
    blockedUntil.removeAll()
    lock.unlock()
  }

  func setTunnelURL(_ url: String) {
    lock.lock()
    publicURL = url
    tunnelError = nil
    lock.unlock()
  }

  func setTunnelError(_ message: String) {
    lock.lock()
    tunnelError = message
    lock.unlock()
  }

  // MARK: Private

  /// Devices seen recently or still under an active block (so a blocked device
  /// stays visible in the menu and can be unblocked). Newest first.
  private func recentDevicesLocked() -> [DeviceSnapshot] {
    let now = Date()
    return devices.compactMap { id, record -> DeviceSnapshot? in
      let block = blockedUntil[id].flatMap { $0 > now ? $0 : nil }
      let isRecent = now.timeIntervalSince(record.lastSeen) <= 120
      guard isRecent || block != nil else { return nil }
      return DeviceSnapshot(
        id: id,
        userAgent: record.userAgent,
        ip: record.ip,
        lastSeen: record.lastSeen,
        blockedUntil: block
      )
    }
    .sorted { $0.lastSeen > $1.lastSeen }
  }

  private func pruneDevicesLocked() {
    let now = Date()
    blockedUntil = blockedUntil.filter { $0.value > now }
    devices = devices.filter { id, record in
      now.timeIntervalSince(record.lastSeen) <= 3600 || blockedUntil[id] != nil
    }
  }

  private static func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  private static func currentStats() -> ProcessStats {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }

    let rssMB = result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : 0
    return ProcessStats(rssMB: rssMB)
  }
}
