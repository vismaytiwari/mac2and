import Foundation
import MachO

struct ProcessStats: Codable {
  let heapMB: Int
  let rssMB: Int
  let cpuPercent: Double
}

struct AppSnapshot {
  let latestMacClip: String
  let macClipHistory: [String]
  let connectedCount: Int
  let lastStats: ProcessStats
  let lastSeenLocalClip: String
  let lastUpdateSource: String?
  let latestUpdatedAt: Int64?
  let syncPaused: Bool
  let publicURL: String?
  let tunnelError: String?
}

final class AppState {
  private let lock = NSLock()
  private var latestMacClip = ""
  private var macClipHistory: [String] = []
  private var connectedDevices: [String: Date] = [:]
  private var lastSeenLocalClip = ""
  private var lastUpdateSource: String?
  private var latestUpdatedAt: Int64?
  private var syncPaused = false
  private var publicURL: String?
  private var tunnelError: String?

  func snapshot() -> AppSnapshot {
    lock.lock()
    defer { lock.unlock() }
    pruneConnectedDevicesLocked()
    return AppSnapshot(
      latestMacClip: latestMacClip,
      macClipHistory: macClipHistory,
      connectedCount: connectedDevices.count,
      lastStats: Self.currentStats(),
      lastSeenLocalClip: lastSeenLocalClip,
      lastUpdateSource: lastUpdateSource,
      latestUpdatedAt: latestUpdatedAt,
      syncPaused: syncPaused,
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

  func clearMacClipboardCache() {
    lock.lock()
    latestMacClip = ""
    lastUpdateSource = nil
    latestUpdatedAt = Self.nowMillis()
    lock.unlock()
  }

  func recordDevice(_ identifier: String) {
    lock.lock()
    connectedDevices[identifier] = Date()
    pruneConnectedDevicesLocked()
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

  private func pruneConnectedDevicesLocked() {
    let cutoff = Date().addingTimeInterval(-60)
    connectedDevices = connectedDevices.filter { $0.value >= cutoff }
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
    return ProcessStats(heapMB: 0, rssMB: rssMB, cpuPercent: 0)
  }
}
