import XCTest

@testable import HyperMetaAI

/// OpenClaw vision 命令的端侧执行：无帧 / 无结果路径
final class OpenClawVisionCommandRunnerTests: XCTestCase {
    override func tearDown() {
        AgentVisionOCRStore.clear()
        AgentVisionSceneStore.clear()
        super.tearDown()
    }

    func testOCRWithoutFrameFails() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .ocr, frame: nil)
        XCTAssertEqual(result, .failure(.noResult))
    }

    func testSceneWithoutFrameFails() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .scene, frame: nil)
        XCTAssertEqual(result, .failure(.noResult))
    }

    func testObjectsWithoutFrameFails() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .objects, frame: nil)
        XCTAssertEqual(result, .failure(.noResult))
    }

    func testOCRBlankImageFailsWithNoResult() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .ocr, frame: Self.blankImage())
        guard case .failure = result else {
            XCTFail("blank image should not produce OCR text")
            return
        }
    }

    func testSceneBlankImageFailsWithNoResult() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .scene, frame: Self.blankImage())
        guard case .failure = result else {
            XCTFail("blank image should not produce a scene summary")
            return
        }
    }

    func testObjectsBlankImageFailsWithNoResult() async {
        let result = await OpenClawVisionCommandRunner.run(kind: .objects, frame: Self.blankImage())
        guard case .failure = result else {
            XCTFail("blank image should not produce object labels")
            return
        }
    }

    private static func blankImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
