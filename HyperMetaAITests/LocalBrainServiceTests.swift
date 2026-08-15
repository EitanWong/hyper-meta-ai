import XCTest
@testable import HyperMetaAI

/// 端侧离线 AI 兜底（Foundation Models）的纯逻辑测试：
/// 设置开关、执行器回调语义（成功 / 空 / 异常 / 超时，且只回调一次）。
final class LocalBrainServiceTests: XCTestCase {

    // MARK: - Settings

    func testSettingsEnabledByDefault() {
        UserDefaults.standard.removeObject(forKey: LocalBrainSettings.key)
        XCTAssertTrue(LocalBrainSettings.enabled)
    }

    func testSettingsRoundtrip() {
        UserDefaults.standard.removeObject(forKey: LocalBrainSettings.key)
        LocalBrainSettings.enabled = false
        XCTAssertFalse(LocalBrainSettings.enabled)
        LocalBrainSettings.enabled = true
        XCTAssertTrue(LocalBrainSettings.enabled)
    }

    func testInstructionsNonEmpty() {
        XCTAssertFalse(LocalBrainInstructions.text.isEmpty)
    }

    // MARK: - Responder

    private final class MockLocalBrain: LocalBrainServicing, @unchecked Sendable {
        let isAvailable: Bool
        var result: Result<String?, Error>
        var delayNanoseconds: UInt64

        init(
            isAvailable: Bool = true,
            result: Result<String?, Error> = .success("本地结果"),
            delayNanoseconds: UInt64 = 0
        ) {
            self.isAvailable = isAvailable
            self.result = result
            self.delayNanoseconds = delayNanoseconds
        }

        func respond(to prompt: String) async throws -> String? {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            switch result {
            case .success(let text):
                return text
            case .failure(let error):
                throw error
            }
        }
    }

    private struct MockError: Error {}

    func testCompletesWithLocalText() async {
        let brain = MockLocalBrain(result: .success("端侧润色标题"))
        let completed = expectation(description: "completed")
        let errored = expectation(description: "errored")
        errored.isInverted = true

        LocalBrainResponder.run(
            brain: brain,
            message: "润色标题",
            onComplete: { text in
                XCTAssertEqual(text, "端侧润色标题")
                completed.fulfill()
            },
            onError: { _ in errored.fulfill() }
        )

        await fulfillment(of: [completed], timeout: 2)
        await fulfillment(of: [errored], timeout: 0.3)
    }

    func testNilResultCompletesWithEmptyText() async {
        let brain = MockLocalBrain(result: .success(nil))
        let completed = expectation(description: "completed")

        LocalBrainResponder.run(
            brain: brain,
            message: "分析场景",
            onComplete: { text in
                XCTAssertEqual(text, "")
                completed.fulfill()
            },
            onError: { _ in XCTFail("空文本不应走错误回调") }
        )

        await fulfillment(of: [completed], timeout: 2)
    }

    func testThrowingReportsLocalErrorKey() async {
        let brain = MockLocalBrain(result: .failure(MockError()))
        let errored = expectation(description: "errored")

        LocalBrainResponder.run(
            brain: brain,
            message: "分析场景",
            onComplete: { _ in XCTFail("异常不应走完成回调") },
            onError: { error in
                XCTAssertEqual(error, "rtmp.scene.assistant.local.error".localized)
                errored.fulfill()
            }
        )

        await fulfillment(of: [errored], timeout: 2)
    }

    func testTimeoutReportsOnceAndSuppressesLateCompletion() async {
        let brain = MockLocalBrain(result: .success("迟到结果"), delayNanoseconds: 500_000_000)
        let errored = expectation(description: "errored")
        let completed = expectation(description: "completed")
        completed.isInverted = true
        var errorCount = 0

        LocalBrainResponder.run(
            brain: brain,
            message: "分析场景",
            timeoutNanoseconds: 20_000_000,
            onComplete: { _ in completed.fulfill() },
            onError: { error in
                errorCount += 1
                XCTAssertEqual(error, "rtmp.scene.assistant.local.timeout".localized)
                errored.fulfill()
            }
        )

        await fulfillment(of: [errored], timeout: 2)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(errorCount, 1, "超时后迟到的完成不应再次回调")
        await fulfillment(of: [completed], timeout: 0.3)
    }

    // MARK: - Service

    func testSharedServiceAvailabilityNeverCrashes() {
        _ = LocalBrainService.shared.isAvailable
    }

    func testUnavailableServiceReturnsNil() async throws {
        guard !LocalBrainService.shared.isAvailable else {
            throw XCTSkip("模拟器已具备端侧 AI 能力，跳过不可用路径")
        }
        let result = try await LocalBrainService.shared.respond(to: "你好")
        XCTAssertNil(result)
    }
}
