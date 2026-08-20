import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class ConversationMessageCodingTests: XCTestCase {
  func testRoundTripPreservesMessageIdentityAndTimestamp() throws {
    let id = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 123_456)
    let message = ConversationMessage(
      id: id,
      role: .assistant,
      content: "Stable record",
      timestamp: timestamp
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)

    XCTAssertEqual(decoded.id, id)
    XCTAssertEqual(decoded.timestamp, timestamp)
    XCTAssertEqual(decoded.role, .assistant)
    XCTAssertEqual(decoded.content, "Stable record")
  }
}
