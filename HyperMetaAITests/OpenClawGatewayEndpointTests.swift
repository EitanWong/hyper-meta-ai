import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class OpenClawGatewayEndpointTests: XCTestCase {
  func testNormalizesWebSocketPrefixAndTrailingSlash() {
    let endpoint = OpenClawGatewayEndpoint(
      host: "  WSS://gateway.local/// ",
      port: 18789,
      usesTLS: false
    )

    XCTAssertEqual(endpoint.url?.absoluteString, "ws://gateway.local:18789")
  }

  func testRejectsInvalidPortAndEmptyHost() {
    XCTAssertNil(OpenClawGatewayEndpoint(host: "gateway.local", port: 0, usesTLS: false).url)
    XCTAssertNil(OpenClawGatewayEndpoint(host: "", port: 18789, usesTLS: true).url)
  }

  func testUsesSecureWebSocketScheme() {
    let endpoint = OpenClawGatewayEndpoint(host: "gateway.local", port: 443, usesTLS: true)

    XCTAssertEqual(endpoint.url?.scheme, "wss")
    XCTAssertEqual(endpoint.url?.port, 443)
  }
}
