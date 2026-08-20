import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

@MainActor
final class WearablesBootstrapTests: XCTestCase {
  func testDetectsTheXCTestRuntime() {
    XCTAssertTrue(UnitTestRuntime.isActive)
  }

  func testUnitTestBootstrapDefersSDKConfiguration() {
    let bootstrap = WearablesBootstrap(isRunningUnitTests: true)

    guard case .testing = bootstrap.state else {
      return XCTFail("The unit-test host must not access Wearables.shared before mock setup")
    }
  }

  func testAppBundleContainsUsableDATConfiguration() {
    guard let configuration = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] else {
      return XCTFail("The app bundle must contain MWDAT configuration")
    }

    XCTAssertEqual(configuration["AppLinkURLScheme"] as? String, "hypermetaai://")
    XCTAssertFalse((configuration["MetaAppID"] as? String)?.isEmpty ?? true)
    XCTAssertFalse((configuration["TeamID"] as? String)?.isEmpty ?? true)

    let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
    XCTAssertTrue(schemes.contains("hypermetaai"))
  }
}
