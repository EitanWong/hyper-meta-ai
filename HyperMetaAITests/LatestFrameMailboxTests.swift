import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class LatestFrameMailboxTests: XCTestCase {
  func testRetainsOnlyTheLatestFrame() {
    let mailbox = LatestFrameMailbox<Int>()
    XCTAssertFalse(mailbox.activate(generation: 3))

    guard case .accepted(let firstOfferReplaced) = mailbox.offer(
      LatestFrameMailboxItem(value: 1, generation: 3, receivedAt: 10)
    ) else {
      return XCTFail("The active generation should accept its first frame")
    }
    XCTAssertFalse(firstOfferReplaced)

    guard case .accepted(let secondOfferReplaced) = mailbox.offer(
      LatestFrameMailboxItem(value: 2, generation: 3, receivedAt: 11)
    ) else {
      return XCTFail("The active generation should accept its replacement frame")
    }
    XCTAssertTrue(secondOfferReplaced)
    XCTAssertEqual(mailbox.depth, 1)

    let item = mailbox.takeLatest()

    XCTAssertEqual(item?.value, 2)
    XCTAssertEqual(item?.generation, 3)
    XCTAssertEqual(item?.receivedAt, 11)
    XCTAssertEqual(mailbox.depth, 0)
  }

  func testConcurrentOffersRemainBounded() {
    let mailbox = LatestFrameMailbox<Int>()
    _ = mailbox.activate(generation: 1)

    DispatchQueue.concurrentPerform(iterations: 1_000) { index in
      _ = mailbox.offer(
        LatestFrameMailboxItem(value: index, generation: 1, receivedAt: Double(index))
      )
    }

    XCTAssertEqual(mailbox.depth, 1)
    XCTAssertNotNil(mailbox.takeLatest())
    XCTAssertEqual(mailbox.depth, 0)
  }

  func testRejectsFramesFromInactiveAndPreviousGenerations() {
    let mailbox = LatestFrameMailbox<Int>()

    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 1, generation: 1, receivedAt: 1)),
      .staleGeneration
    )
    XCTAssertFalse(mailbox.activate(generation: 1))
    _ = mailbox.offer(LatestFrameMailboxItem(value: 2, generation: 1, receivedAt: 2))

    XCTAssertTrue(mailbox.activate(generation: 2))
    XCTAssertEqual(mailbox.depth, 0)
    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 3, generation: 1, receivedAt: 3)),
      .staleGeneration
    )
    XCTAssertEqual(
      mailbox.offer(LatestFrameMailboxItem(value: 4, generation: 2, receivedAt: 4)),
      .accepted(replacedExistingFrame: false)
    )
  }
}
