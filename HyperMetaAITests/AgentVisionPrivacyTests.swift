import XCTest

@testable import HyperMetaAI

/// 视觉数据隐私：清除全部视觉数据（共享内存态 + 广播事件）
final class AgentVisionPrivacyTests: XCTestCase {
    override func tearDown() {
        // 保证用例之间不残留共享内存态
        AgentVisionOCRStore.clear()
        AgentVisionSceneStore.clear()
        super.tearDown()
    }

    func testClearAllClearsOCRAndSceneStores() {
        AgentVisionOCRStore.set("Hello 世界")
        AgentVisionSceneStore.set("a desk with a laptop")
        XCTAssertEqual(AgentVisionOCRStore.latestText, "Hello 世界")
        XCTAssertEqual(AgentVisionSceneStore.latestSummary, "a desk with a laptop")

        AgentVisionDataPrivacy.clearAll()

        XCTAssertNil(AgentVisionOCRStore.latestText)
        XCTAssertNil(AgentVisionSceneStore.latestSummary)
    }

    func testClearAllPostsDataClearedNotification() {
        let expectation = expectation(description: "vision data cleared notification")
        let token = NotificationCenter.default.addObserver(
            forName: .agentVisionDataCleared,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        AgentVisionDataPrivacy.clearAll()

        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(token)
    }

    func testClearAllIdempotentWhenEmpty() {
        // 无数据时清理不崩溃、不报错
        AgentVisionDataPrivacy.clearAll()
        AgentVisionDataPrivacy.clearAll()
        XCTAssertNil(AgentVisionOCRStore.latestText)
        XCTAssertNil(AgentVisionSceneStore.latestSummary)
    }
}
