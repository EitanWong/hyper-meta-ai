import XCTest

@testable import HyperMetaAI

/// 系统入口 → App 内导航路由：请求 / 消费生命周期
@MainActor
final class AppNavigationRouterTests: XCTestCase {
  override func tearDown() {
    _ = AppNavigationRouter.shared.consume()
    super.tearDown()
  }

  func testInitialStateIsIdle() {
    XCTAssertNil(AppNavigationRouter.shared.pendingDestination)
  }

  func testRequestThenConsume() {
    AppNavigationRouter.shared.request(.agentSettings(.reminders))
    XCTAssertEqual(AppNavigationRouter.shared.pendingDestination, .agentSettings(.reminders))

    XCTAssertEqual(AppNavigationRouter.shared.consume(), .agentSettings(.reminders))
    XCTAssertNil(AppNavigationRouter.shared.pendingDestination)
    XCTAssertNil(AppNavigationRouter.shared.consume(), "重复消费应为 nil")
  }

  func testRequestIsIdempotent() {
    AppNavigationRouter.shared.request(.agentSettings(.reminders))
    AppNavigationRouter.shared.request(.agentSettings(.reminders))
    XCTAssertEqual(AppNavigationRouter.shared.consume(), .agentSettings(.reminders))
  }

  func testDestinationEquatable() {
    XCTAssertEqual(AppNavigationDestination.agentSettings(.reminders), .agentSettings(.reminders))
    let photoID = UUID()
    XCTAssertEqual(AppNavigationDestination.gallery(photoID), .gallery(photoID))
    XCTAssertNotEqual(
      AppNavigationDestination.gallery(photoID),
      AppNavigationDestination.gallery(UUID())
    )
    XCTAssertNotEqual(
      AppNavigationDestination.gallery(photoID),
      AppNavigationDestination.agentSettings(.reminders)
    )
  }

  func testFilteredConsumeOnlyTakesMatchingDestination() {
    let photoID = UUID()
    AppNavigationRouter.shared.request(.gallery(photoID))

    // 不匹配的消费者不得取走请求
    let settingsResult = AppNavigationRouter.shared.consume(where: {
      if case .agentSettings = $0 { return true }
      return false
    })
    XCTAssertNil(settingsResult)
    XCTAssertEqual(
      AppNavigationRouter.shared.pendingDestination,
      .gallery(photoID),
      "不匹配的过滤消费不应清空待处理请求"
    )

    // 匹配的消费者取走请求
    let galleryResult = AppNavigationRouter.shared.consume(where: {
      if case .gallery = $0 { return true }
      return false
    })
    XCTAssertEqual(galleryResult, .gallery(photoID))
    XCTAssertNil(AppNavigationRouter.shared.pendingDestination)
  }
}
