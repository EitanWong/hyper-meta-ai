import Foundation
import XCTest

@testable import HyperMetaAI

final class RTMPDestinationStoreTests: XCTestCase {

  override func setUp() {
    super.setUp()
    RTMPDestinationStore.destinations = []
  }

  override func tearDown() {
    RTMPDestinationStore.destinations = []
    super.tearDown()
  }

  func testAddStoresNewestFirst() {
    XCTAssertTrue(RTMPDestinationStore.add(name: "Bilibili", url: "rtmp://a.example.com/app/key1"))
    XCTAssertTrue(RTMPDestinationStore.add(name: "Douyin", url: "rtmp://b.example.com/app/key2"))

    XCTAssertEqual(RTMPDestinationStore.destinations.count, 2)
    XCTAssertEqual(RTMPDestinationStore.destinations.first?.name, "Douyin")
    XCTAssertTrue(RTMPDestinationStore.destinations.first?.isEnabled == true)
  }

  func testAddRejectsEmptyAndDuplicate() {
    XCTAssertFalse(RTMPDestinationStore.add(name: " ", url: "rtmp://a.example.com/app/k"))
    XCTAssertFalse(RTMPDestinationStore.add(name: "Bilibili", url: " "))
    XCTAssertTrue(RTMPDestinationStore.add(name: "Bilibili", url: "rtmp://a.example.com/app/k"))
    XCTAssertFalse(RTMPDestinationStore.add(name: "Bilibili 2", url: "rtmp://a.example.com/app/k"))
  }

  func testAddEnforcesMaxCount() {
    for index in 0..<5 {
      let ok = RTMPDestinationStore.add(
        name: "Dest \(index)",
        url: "rtmp://a.example.com/app/key\(index)"
      )
      XCTAssertEqual(ok, index < RTMPDestinationStore.maxCount)
    }
    XCTAssertEqual(RTMPDestinationStore.destinations.count, RTMPDestinationStore.maxCount)
  }

  func testUpdateRenamesAndRejectsDuplicateURL() {
    _ = RTMPDestinationStore.add(name: "A", url: "rtmp://a.example.com/app/1")
    _ = RTMPDestinationStore.add(name: "B", url: "rtmp://b.example.com/app/2")
    let first = RTMPDestinationStore.destinations[0]

    XCTAssertTrue(RTMPDestinationStore.update(id: first.id, name: "B2", url: "rtmp://b.example.com/app/2"))
    XCTAssertFalse(RTMPDestinationStore.update(id: first.id, name: "B2", url: "rtmp://a.example.com/app/1"))
    XCTAssertEqual(RTMPDestinationStore.destinations.first?.name, "B2")
  }

  func testToggleAndDelete() throws {
    _ = RTMPDestinationStore.add(name: "A", url: "rtmp://a.example.com/app/1")
    let id = try XCTUnwrap(RTMPDestinationStore.destinations.first?.id)

    XCTAssertTrue(RTMPDestinationStore.toggle(id: id))
    XCTAssertEqual(RTMPDestinationStore.destinations.first?.isEnabled, false)
    XCTAssertTrue(RTMPDestinationStore.toggle(id: id))
    XCTAssertEqual(RTMPDestinationStore.destinations.first?.isEnabled, true)

    RTMPDestinationStore.delete(id: id)
    XCTAssertTrue(RTMPDestinationStore.destinations.isEmpty)
  }
}

final class RTMPParallelSessionStateTests: XCTestCase {

  private func destination(_ id: UUID = UUID(), enabled: Bool = true) -> RTMPDestination {
    RTMPDestination(id: id, name: "Dest", url: "rtmp://a.example.com/app/key", isEnabled: enabled)
  }

  func testBeginKeepsOnlyEnabledDestinationsAsConnecting() {
    var session = RTMPParallelSessionState()
    let a = destination()
    let b = destination(enabled: false)

    session.begin(destinations: [a, b])

    XCTAssertEqual(session.destinations.count, 1)
    XCTAssertEqual(session.destinations.first?.connectionState, .connecting)
    XCTAssertEqual(session.connectingCount, 1)
    XCTAssertEqual(session.aggregate, .connecting)
  }

  func testMarkStreamingAndFullyStreaming() {
    var session = RTMPParallelSessionState()
    let a = destination()
    let b = destination()
    session.begin(destinations: [a, b])

    session.markStreaming(id: a.id)
    XCTAssertEqual(session.streamingCount, 1)
    XCTAssertFalse(session.isFullyStreaming)
    XCTAssertEqual(session.aggregate, .streaming)

    session.markStreaming(id: b.id)
    XCTAssertTrue(session.isFullyStreaming)
    XCTAssertEqual(session.streamingCount, 2)
  }

  func testAggregateFailsWhenAllFail() {
    var session = RTMPParallelSessionState()
    let a = destination()
    let b = destination()
    session.begin(destinations: [a, b])

    session.markFailed(id: a.id, message: "timeout")
    session.markFailed(id: b.id, message: "rejected")
    XCTAssertEqual(session.failedCount, 2)
    XCTAssertEqual(session.aggregate, .failed)
  }

  func testAggregateStreamsWhileSomeFailed() {
    var session = RTMPParallelSessionState()
    let a = destination()
    let b = destination()
    session.begin(destinations: [a, b])

    session.markStreaming(id: a.id)
    session.markFailed(id: b.id, message: "timeout")

    XCTAssertEqual(session.aggregate, .streaming)
    XCTAssertEqual(session.failedCount, 1)
  }

  func testStopResetsAllToIdle() {
    var session = RTMPParallelSessionState()
    let a = destination()
    session.begin(destinations: [a])
    session.markStreaming(id: a.id)

    session.stop()

    XCTAssertEqual(session.destinations.first?.connectionState, .idle)
    XCTAssertEqual(session.aggregate, .idle)
    XCTAssertFalse(session.isFullyStreaming)
  }

  func testEmptySessionIsIdle() {
    let session = RTMPParallelSessionState()
    XCTAssertEqual(session.aggregate, .idle)
    XCTAssertEqual(session.streamingCount, 0)
    XCTAssertFalse(session.isFullyStreaming)
  }
}

final class RTMPParallelDynamicSessionTests: XCTestCase {

  private func destination(_ id: UUID = UUID(), enabled: Bool = true) -> RTMPDestination {
    RTMPDestination(id: id, name: "Dest", url: "rtmp://a.example.com/app/key", isEnabled: enabled)
  }

  func testAddAppendsNewDestinationAsConnecting() {
    var session = RTMPParallelSessionState()
    session.begin(destinations: [destination()])

    let extra = destination()
    session.add(extra)

    XCTAssertEqual(session.destinations.count, 2)
    XCTAssertEqual(session.destinations.last?.connectionState, .connecting)
    XCTAssertEqual(session.connectingCount, 2)
  }

  func testAddIgnoresDuplicateID() {
    var session = RTMPParallelSessionState()
    let a = destination()
    session.begin(destinations: [a])

    session.add(a)

    XCTAssertEqual(session.destinations.count, 1)
  }

  func testRemoveDropsDestinationAndUpdatesAggregate() {
    var session = RTMPParallelSessionState()
    let a = destination()
    let b = destination()
    session.begin(destinations: [a, b])
    session.markStreaming(id: a.id)
    session.markFailed(id: b.id, message: "timeout")
    XCTAssertEqual(session.aggregate, .streaming)

    session.remove(id: b.id)

    XCTAssertEqual(session.destinations.count, 1)
    XCTAssertEqual(session.failedCount, 0)
    XCTAssertTrue(session.isFullyStreaming)
  }

  func testRetryMovesFailedBackToConnecting() {
    var session = RTMPParallelSessionState()
    let a = destination()
    session.begin(destinations: [a])
    session.markFailed(id: a.id, message: "timeout")
    XCTAssertEqual(session.aggregate, .failed)

    session.retry(id: a.id)

    XCTAssertEqual(session.destinations.first?.connectionState, .connecting)
    XCTAssertEqual(session.aggregate, .connecting)
  }

  func testRetryUnknownIDIsNoop() {
    var session = RTMPParallelSessionState()
    session.begin(destinations: [destination()])

    session.retry(id: UUID())

    XCTAssertEqual(session.destinations.count, 1)
  }
}

final class RTMPParallelRetryPolicyTests: XCTestCase {

  func testDefaultRetriesOnce() {
    let policy = RTMPParallelRetryPolicy()
    XCTAssertEqual(policy.maxRetries, 1)
    XCTAssertTrue(policy.shouldRetry(afterFailedAttempt: 0))
    XCTAssertFalse(policy.shouldRetry(afterFailedAttempt: 1))
  }

  func testZeroDisablesRetry() {
    let policy = RTMPParallelRetryPolicy(maxRetries: 0)
    XCTAssertFalse(policy.shouldRetry(afterFailedAttempt: 0))
  }

  func testNegativeMaxRetriesClampedToZero() {
    let policy = RTMPParallelRetryPolicy(maxRetries: -3)
    XCTAssertEqual(policy.maxRetries, 0)
    XCTAssertFalse(policy.shouldRetry(afterFailedAttempt: 0))
  }
}
