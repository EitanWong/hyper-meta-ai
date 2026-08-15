import XCTest
@testable import HyperMetaAI

final class VisionSceneTextProcessorTests: XCTestCase {

    private func item(_ identifier: String, _ confidence: Float) -> VisionSceneItem {
        VisionSceneItem(identifier: identifier, confidence: confidence)
    }

    func testSceneTokensFilterAndOrder() {
        let result = VisionSceneResult(
            classifications: [
                item("Restaurant", 0.9),
                item("Food", 0.6),
                item("Indoor", 0.1),
                item("Coffee Shop", 0.7),
                item("Dining Table", 0.5),
            ],
            animals: []
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.sceneTokens(from: result),
            ["Restaurant", "Coffee Shop", "Food"]
        )
    }

    func testSceneTokensMaxCount() {
        let result = VisionSceneResult(
            classifications: [item("A", 0.9), item("B", 0.8), item("C", 0.7), item("D", 0.6)],
            animals: []
        )
        XCTAssertEqual(VisionSceneTextProcessor.sceneTokens(from: result, maxCount: 2), ["A", "B"])
    }

    func testAnimalTokensDedupeAndFilter() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [
                item("Cat", 0.9),
                item("Dog", 0.3),
                item("Cat", 0.85),
                item("Bird", 0.7),
            ]
        )
        XCTAssertEqual(VisionSceneTextProcessor.animalTokens(from: result), ["Cat", "Bird"])
    }

    func testSummaryWithSceneOnly() {
        let result = VisionSceneResult(
            classifications: [item("Restaurant", 0.9), item("Food", 0.6)],
            animals: []
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.sceneonly".localized, "Restaurant, Food")
        )
    }

    func testSummaryWithSceneAndAnimals() {
        let result = VisionSceneResult(
            classifications: [item("Park", 0.8)],
            animals: [item("Dog", 0.9)]
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary".localized, "Park", "Dog")
        )
    }

    func testSummaryWithAnimalsOnly() {
        let result = VisionSceneResult(classifications: [], animals: [item("Cat", 0.9)])
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.animalonly".localized, "Cat")
        )
    }

    func testSummaryEmptyWhenNothingRecognized() {
        let result = VisionSceneResult(classifications: [item("Indoor", 0.1)], animals: [item("Dog", 0.2)])
        XCTAssertEqual(VisionSceneTextProcessor.summaryText(from: result), "")
        XCTAssertTrue(VisionSceneTextProcessor.displayText(from: result).isEmpty)
    }
}

final class VisionSceneObjectTests: XCTestCase {

    private func item(_ identifier: String, _ confidence: Float) -> VisionSceneItem {
        VisionSceneItem(identifier: identifier, confidence: confidence)
    }

    func testObjectTokensFilterDedupeAndOrder() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [],
            objects: [
                item("Mug", 0.9),
                item("Laptop", 0.3),
                item("Mug", 0.85),
                item("Bottle", 0.7),
            ]
        )
        XCTAssertEqual(VisionSceneTextProcessor.objectTokens(from: result), ["Mug", "Bottle"])
    }

    func testObjectTokensMaxCount() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [],
            objects: [item("A", 0.9), item("B", 0.8), item("C", 0.7), item("D", 0.6)]
        )
        XCTAssertEqual(VisionSceneTextProcessor.objectTokens(from: result, maxCount: 2), ["A", "B"])
    }

    func testObjectCandidatesExcludeSceneAnimalsAndSceneTop() {
        let items = [
            item("Restaurant", 0.9),   // 场景词 → 排除
            item("Cat", 0.85),         // 动物词 → 排除
            item("Coffee Cup", 0.8),   // 已入 sceneTop → 排除
            item("Laptop", 0.75),      // 保留
            item("Bottle", 0.65),      // 保留
            item("Pen", 0.3),          // 置信度过低 → 排除
        ]
        let candidates = VisionSceneTextProcessor.objectCandidates(
            from: items,
            sceneTop: ["Restaurant", "Coffee Cup", "Table"]
        )
        XCTAssertEqual(candidates.map(\.identifier), ["Laptop", "Bottle"])
    }

    func testObjectCandidatesEmptyWhenNothingQualifies() {
        let items = [
            item("Restaurant", 0.9),
            item("Cat", 0.85),
            item("Mug", 0.8),
        ]
        let candidates = VisionSceneTextProcessor.objectCandidates(
            from: items,
            sceneTop: ["Restaurant", "Mug"]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testObjectSummaryJoinsLabels() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [],
            objects: [item("Mug", 0.9), item("Laptop", 0.7), item("Bottle", 0.5), item("Pen", 0.4)]
        )
        XCTAssertEqual(VisionSceneTextProcessor.objectSummary(from: result), "Mug, Laptop, Bottle, Pen")
    }

    func testSummaryWithSceneAnimalsAndObjects() {
        let result = VisionSceneResult(
            classifications: [item("Restaurant", 0.9)],
            animals: [item("Cat", 0.9)],
            objects: [item("Mug", 0.8)]
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.all".localized, "Restaurant", "Cat", "Mug")
        )
    }

    func testSummaryWithSceneAndObjects() {
        let result = VisionSceneResult(
            classifications: [item("Park", 0.8)],
            animals: [],
            objects: [item("Bench", 0.9)]
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.sceneobjects".localized, "Park", "Bench")
        )
    }

    func testSummaryWithAnimalsAndObjects() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [item("Dog", 0.9)],
            objects: [item("Frisbee", 0.8)]
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.animalobjects".localized, "Dog", "Frisbee")
        )
    }

    func testSummaryWithObjectsOnly() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [],
            objects: [item("Mug", 0.9)]
        )
        XCTAssertEqual(
            VisionSceneTextProcessor.summaryText(from: result),
            String(format: "agent.vision.scene.summary.objectsonly".localized, "Mug")
        )
    }

    func testIsEmptyConsidersObjects() {
        let result = VisionSceneResult(
            classifications: [],
            animals: [],
            objects: [item("Mug", 0.9)]
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(VisionSceneTextProcessor.summaryText(from: result),
                       String(format: "agent.vision.scene.summary.objectsonly".localized, "Mug"))
    }
}

final class AgentVisionSceneCommandParserTests: XCTestCase {

    func testParsesExactPhrases() {
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("看看"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("看看这是什么"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("识别场景"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("画面里有什么"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("这是什么"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("看看场景"))
    }

    func testParsesObjectPhrases() {
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("识别物体"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("有什么东西"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("画面里有什么东西"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("识别物体吧"))
    }

    func testObjectPhrasesDoNotSwallowPlainChat() {
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("识别物体的原理"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("房间里有什么东西在响"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("画面里有什么东西我该注意"))
    }

    func testStripsTrailingParticles() {
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("看看这是什么呀"))
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("识别场景吧"))
    }

    func testDoesNotInterceptPlainChat() {
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("看看这个怎么用"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("这是什么意思"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("帮我看看"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("今天天气怎么样"))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse(""))
        XCTAssertFalse(AgentVisionSceneCommandParser.parse("   "))
    }

    func testTrimsWhitespace() {
        XCTAssertTrue(AgentVisionSceneCommandParser.parse("  看看  "))
    }
}
