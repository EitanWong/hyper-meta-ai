/*
 * Realtime Session Configuration Gate
 * Prevents media capture from starting before a provider confirms its session
 * configuration, including the negotiated audio contract.
 */

import Foundation

final class RealtimeSessionConfigurationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var activeGeneration: Int?
  private var isConfigurationConfirmed = false

  func activate(generation: Int) {
    lock.lock()
    activeGeneration = generation
    isConfigurationConfirmed = false
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    activeGeneration = nil
    isConfigurationConfirmed = false
    lock.unlock()
  }

  /// Returns true exactly once for the current session generation.
  func confirm(generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard activeGeneration == generation, !isConfigurationConfirmed else {
      return false
    }
    isConfigurationConfirmed = true
    return true
  }
}
