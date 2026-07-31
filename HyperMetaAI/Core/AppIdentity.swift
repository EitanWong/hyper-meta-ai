import Foundation

/*
 * App Identity
 * Centralizes product-facing identifiers that are shared by runtime services.
 */

enum AppIdentity {
  static let displayName = "Hyper Meta AI"
  static let urlScheme = "hypermetaai"
  static let legacyURLScheme = "turbometa"
  static let loggingSubsystem = Bundle.main.bundleIdentifier ?? "com.lunflux.hyper-meta-ai"

  static var isRunningPreview: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    #else
    false
    #endif
  }
}
