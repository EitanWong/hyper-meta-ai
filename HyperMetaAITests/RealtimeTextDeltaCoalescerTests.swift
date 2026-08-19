import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class RealtimeTextDeltaCoalescerTests: XCTestCase {
  func testFlushBatchesMultipleDeltasIntoOneBackgroundSnapshot() {
    let snapshotExpectation = expectation(description: "coalesced snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.flush",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 4) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      snapshotExpectation.fulfill()
    }

    XCTAssertEqual(coalescer.append("Hello"), .accepted)
    XCTAssertEqual(coalescer.append(" world"), .accepted)
    coalescer.flush()

    wait(for: [snapshotExpectation], timeout: 1)

    lock.lock()
    let snapshot = snapshots.first
    lock.unlock()
    XCTAssertEqual(snapshot?.sessionGeneration, 4)
    XCTAssertEqual(snapshot?.responseID, 1)
    XCTAssertEqual(snapshot?.sequence, 1)
    XCTAssertEqual(snapshot?.text, "Hello world")
    XCTAssertFalse(snapshot?.isFinal ?? true)
    XCTAssertEqual(snapshot?.coalescedDeltaCount, 2)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertEqual(metrics.inputDeltas, 2)
    XCTAssertEqual(metrics.publishedSnapshots, 1)
    XCTAssertEqual(metrics.currentPendingDeltas, 0)
    XCTAssertEqual(metrics.maximumPendingDeltas, 2)
  }

  func testFinalProviderTextReplacesBufferedDeltaAndIsDeliveredOnce() {
    let finalExpectation = expectation(description: "final snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.final",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var finalSnapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 9) { snapshot in
      guard snapshot.isFinal else { return }
      lock.lock()
      finalSnapshots.append(snapshot)
      lock.unlock()
      finalExpectation.fulfill()
    }

    XCTAssertEqual(coalescer.append("partial"), .accepted)
    coalescer.finish(finalText: "authoritative final text")
    coalescer.finish(finalText: "duplicate completion")

    wait(for: [finalExpectation], timeout: 1)

    lock.lock()
    let snapshots = finalSnapshots
    lock.unlock()
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots.first?.text, "authoritative final text")
    XCTAssertTrue(snapshots.first?.isFinal ?? false)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertEqual(metrics.completedResponses, 1)
    XCTAssertEqual(metrics.publishedSnapshots, 1)
  }

  func testNewResponseAfterCompletionUsesANewResponseID() {
    let firstFinalExpectation = expectation(description: "first response final")
    let secondSnapshotExpectation = expectation(description: "second response snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.responses",
      publishingInterval: 60
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 2) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.isFinal {
        firstFinalExpectation.fulfill()
      } else if snapshot.responseID == 2 {
        secondSnapshotExpectation.fulfill()
      }
    }

    XCTAssertEqual(coalescer.append("first"), .accepted)
    coalescer.finish()
    wait(for: [firstFinalExpectation], timeout: 1)

    XCTAssertEqual(coalescer.append("second"), .accepted)
    coalescer.flush()
    wait(for: [secondSnapshotExpectation], timeout: 1)

    lock.lock()
    let delivered = snapshots
    lock.unlock()
    XCTAssertEqual(delivered.map(\.responseID), [1, 2])
    XCTAssertEqual(delivered.map(\.text), ["first", "second"])
  }

  func testRestartDropsPendingTextAndIncomingDeltasStayBounded() {
    let snapshotExpectation = expectation(description: "new session snapshot")
    let coalescer = RealtimeTextDeltaCoalescer(
      label: "RealtimeTextDeltaCoalescerTests.bounds",
      publishingInterval: 60,
      maximumPendingDeltaCount: 4,
      maximumPendingCharacterCount: 4
    )
    defer { coalescer.stop() }

    let lock = NSLock()
    var snapshots: [RealtimeTextDeltaSnapshot] = []
    coalescer.start(generation: 1) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.sessionGeneration == 2 {
        snapshotExpectation.fulfill()
      }
    }
    XCTAssertEqual(coalescer.append("old"), .accepted)

    coalescer.start(generation: 2) { snapshot in
      lock.lock()
      snapshots.append(snapshot)
      lock.unlock()
      if snapshot.sessionGeneration == 2 {
        snapshotExpectation.fulfill()
      }
    }
    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
      _ = coalescer.append("x")
    }
    coalescer.flush()

    wait(for: [snapshotExpectation], timeout: 1)

    lock.lock()
    let delivered = snapshots
    lock.unlock()
    XCTAssertEqual(delivered.last?.sessionGeneration, 2)
    XCTAssertEqual(delivered.last?.text, "xxxx")
    XCTAssertEqual(delivered.last?.coalescedDeltaCount, 4)

    let metrics = coalescer.performanceSnapshot()
    XCTAssertLessThanOrEqual(metrics.maximumPendingDeltas, 4)
    XCTAssertLessThanOrEqual(metrics.maximumPendingCharacters, 4)
    XCTAssertEqual(metrics.pendingBufferDrops, 996)

    coalescer.stop()
    XCTAssertEqual(coalescer.append("after stop"), .inactive)
  }
}
