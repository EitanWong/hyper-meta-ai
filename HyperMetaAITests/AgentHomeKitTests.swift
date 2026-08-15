import Foundation
import XCTest

@testable import HyperMetaAI

// MARK: - Mock Provider

private final class MockHomeKitProvider: AgentHomeKitProviding {
  var authorization: AgentHomeKitAuthorization = .authorized
  var storedDevices: [AgentHomeKitDevice] = []
  var shouldFail = false
  private(set) var powerCalls: [(deviceID: String, on: Bool)] = []
  private(set) var brightnessCalls: [(deviceID: String, percent: Int)] = []
  private(set) var temperatureCalls: [(deviceID: String, celsius: Double)] = []

  func devices() async -> [AgentHomeKitDevice] { storedDevices }

  func setPower(deviceID: String, on: Bool) async throws {
    if shouldFail { throw NSError(domain: "mock", code: 1) }
    powerCalls.append((deviceID, on))
  }

  func setBrightness(deviceID: String, percent: Int) async throws {
    if shouldFail { throw NSError(domain: "mock", code: 1) }
    brightnessCalls.append((deviceID, percent))
  }

  func setTemperature(deviceID: String, celsius: Double) async throws {
    if shouldFail { throw NSError(domain: "mock", code: 1) }
    temperatureCalls.append((deviceID, celsius))
  }
}

private func device(
  id: String,
  name: String,
  room: String? = nil,
  kind: AgentHomeKitDevice.Kind = .light,
  isOn: Bool? = nil,
  brightness: Int? = nil,
  targetTemperature: Double? = nil,
  isLocked: Bool? = nil
) -> AgentHomeKitDevice {
  AgentHomeKitDevice(
    id: id,
    name: name,
    roomName: room,
    kind: kind,
    isOn: isOn,
    brightness: brightness,
    currentTemperature: nil,
    targetTemperature: targetTemperature,
    isLocked: isLocked
  )
}

private let livingRoomLight = device(
  id: "light-1", name: "客厅灯", room: "客厅", kind: .light,
  isOn: true, brightness: 60
)
private let bedRoomLight = device(
  id: "light-2", name: "卧室灯", room: "卧室", kind: .light, isOn: false
)
private let airCon = device(
  id: "ac-1", name: "空调", room: "客厅", kind: .thermostat,
  targetTemperature: 26
)
private let frontLock = device(
  id: "lock-1", name: "门锁", room: "玄关", kind: .lock, isLocked: true
)

// MARK: - Parser

final class AgentHomeKitCommandParserTests: XCTestCase {
  func testTurnOnVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("打开客厅灯"),
      .control(target: "客厅灯", action: .turnOn)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯打开"),
      .control(target: "客厅灯", action: .turnOn)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("开启卧室灯"),
      .control(target: "卧室灯", action: .turnOn)
    )
  }

  func testTurnOffVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("关掉客厅灯"),
      .control(target: "客厅灯", action: .turnOff)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯关掉"),
      .control(target: "客厅灯", action: .turnOff)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("关上卧室灯"),
      .control(target: "卧室灯", action: .turnOff)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把空调关闭"),
      .control(target: "空调", action: .turnOff)
    )
  }

  func testBrightnessVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯调到50%"),
      .control(target: "客厅灯", action: .setBrightness(50))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯调到50％"),
      .control(target: "客厅灯", action: .setBrightness(50))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("客厅灯亮度调到30"),
      .control(target: "客厅灯", action: .setBrightness(30))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯调亮"),
      .control(target: "客厅灯", action: .brighten)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把卧室灯调暗"),
      .control(target: "卧室灯", action: .dim)
    )
    // 亮度越界收敛
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把客厅灯调到150%"),
      .control(target: "客厅灯", action: .setBrightness(100))
    )
  }

  func testTemperatureVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把空调调到26度"),
      .control(target: "空调", action: .setTemperature(26))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("空调温度调到26度"),
      .control(target: "空调", action: .setTemperature(26))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把空调温度设为24"),
      .control(target: "空调", action: .setTemperature(24))
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把空调调到26.5度"),
      .control(target: "空调", action: .setTemperature(26.5))
    )
  }

  func testAllVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("关掉所有灯"),
      .controlAll(category: "灯", action: .turnOff)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("把所有灯关掉"),
      .controlAll(category: "灯", action: .turnOff)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("所有灯都打开"),
      .controlAll(category: "灯", action: .turnOn)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("打开所有灯"),
      .controlAll(category: "灯", action: .turnOn)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("全屋的灯打开"),
      .controlAll(category: "灯", action: .turnOn)
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("关掉所有开关"),
      .controlAll(category: "开关", action: .turnOff)
    )
  }

  func testQueryVariants() {
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("客厅灯什么状态"),
      .query(target: "客厅灯")
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("卧室灯开着吗"),
      .query(target: "卧室灯")
    )
    XCTAssertEqual(
      AgentHomeKitCommandParser.parse("空调温度多少"),
      .query(target: "空调")
    )
  }

  func testListVariants() {
    XCTAssertEqual(AgentHomeKitCommandParser.parse("家里有什么设备"), .listDevices)
    XCTAssertEqual(AgentHomeKitCommandParser.parse("有什么智能设备"), .listDevices)
  }

  func testDoesNotSwallowOrdinarySpeech() {
    XCTAssertNil(AgentHomeKitCommandParser.parse("今天天气怎么样"))
    XCTAssertNil(AgentHomeKitCommandParser.parse("打开App"))
    XCTAssertNil(AgentHomeKitCommandParser.parse("打开微信"))
    XCTAssertNil(AgentHomeKitCommandParser.parse("帮我打开"))
    XCTAssertNil(AgentHomeKitCommandParser.parse("关掉"))
    XCTAssertNil(AgentHomeKitCommandParser.parse(""))
    XCTAssertNil(AgentHomeKitCommandParser.parse("客厅"))
    XCTAssertNil(AgentHomeKitCommandParser.parse("把门打开看看"))
  }
}

// MARK: - Matcher

final class AgentHomeKitTargetMatcherTests: XCTestCase {
  private let devices = [livingRoomLight, bedRoomLight, airCon, frontLock]

  func testExactNameMatch() {
    let matched = AgentHomeKitTargetMatcher.match(target: "客厅灯", devices: devices)
    XCTAssertEqual(matched.map(\.id), ["light-1"])
  }

  func testStrippedSuffixMatch() {
    // 「客厅」匹配「客厅灯」（设备名去掉「灯」尾缀后相等）
    let matched = AgentHomeKitTargetMatcher.match(target: "客厅", devices: [livingRoomLight])
    XCTAssertEqual(matched.map(\.id), ["light-1"])
  }

  func testRoomNameMatch() {
    // 「卧室」匹配房间里的卧室灯
    let matched = AgentHomeKitTargetMatcher.match(target: "卧室", devices: devices)
    XCTAssertEqual(matched.map(\.id), ["light-2"])
  }

  func testContainedNameMatch() {
    let custom = device(id: "c1", name: "书房小台灯", room: "书房")
    let matched = AgentHomeKitTargetMatcher.match(target: "台灯", devices: [custom])
    XCTAssertEqual(matched.map(\.id), ["c1"])
  }

  func testRoomMatchReturnsMultipleDevices() {
    let matched = AgentHomeKitTargetMatcher.match(target: "客厅", devices: devices)
    XCTAssertEqual(matched.map(\.id), ["light-1", "ac-1"])
  }

  func testNoMatch() {
    XCTAssertTrue(AgentHomeKitTargetMatcher.match(target: "车库", devices: devices).isEmpty)
    XCTAssertTrue(AgentHomeKitTargetMatcher.match(target: "", devices: devices).isEmpty)
  }

  func testNormalizeStripsPunctuation() {
    XCTAssertEqual(AgentHomeKitTargetMatcher.normalize("客厅的灯"), "客厅灯")
    XCTAssertEqual(AgentHomeKitTargetMatcher.stripped("客厅灯"), "客厅")
  }
}

// MARK: - Formatter

final class AgentHomeKitFormatterTests: XCTestCase {
  func testStatusTexts() {
    XCTAssertEqual(
      AgentHomeKitFormatter.deviceStatus(livingRoomLight),
      String(format: "agent.homekit.status.on.brightness".localized, "客厅灯", "60")
    )
    XCTAssertEqual(
      AgentHomeKitFormatter.deviceStatus(bedRoomLight),
      String(format: "agent.homekit.status.off".localized, "卧室灯")
    )
    XCTAssertEqual(
      AgentHomeKitFormatter.deviceStatus(airCon),
      String(format: "agent.homekit.status.temperature".localized, "空调", "26")
    )
    XCTAssertEqual(
      AgentHomeKitFormatter.deviceStatus(frontLock),
      String(format: "agent.homekit.status.locked".localized, "门锁")
    )
  }

  func testControlledTexts() {
    XCTAssertEqual(
      AgentHomeKitFormatter.controlled(livingRoomLight, action: .turnOn),
      String(format: "agent.homekit.controlled.on".localized, "客厅灯")
    )
    XCTAssertEqual(
      AgentHomeKitFormatter.controlled(livingRoomLight, action: .setBrightness(50)),
      String(format: "agent.homekit.controlled.brightness".localized, "客厅灯", "50")
    )
    XCTAssertEqual(
      AgentHomeKitFormatter.controlled(airCon, action: .setTemperature(26)),
      String(format: "agent.homekit.controlled.temperature".localized, "空调", "26")
    )
  }

  func testTrimmedNumber() {
    XCTAssertEqual(AgentHomeKitFormatter.trimmedNumber(26), "26")
    XCTAssertEqual(AgentHomeKitFormatter.trimmedNumber(26.5), "26.5")
    XCTAssertEqual(AgentHomeKitFormatter.trimmedNumber(0), "0")
  }
}

// MARK: - Executor

final class AgentHomeKitExecutorTests: XCTestCase {
  private func makeProvider(devices: [AgentHomeKitDevice]) -> MockHomeKitProvider {
    let provider = MockHomeKitProvider()
    provider.storedDevices = devices
    return provider
  }

  func testControlSingleDevice() async {
    let provider = makeProvider(devices: [livingRoomLight])
    let reply = await AgentHomeKitExecutor.execute(
      .control(target: "客厅灯", action: .turnOn),
      provider: provider
    )
    XCTAssertEqual(provider.powerCalls.count, 1)
    XCTAssertEqual(provider.powerCalls[0].deviceID, "light-1")
    XCTAssertEqual(provider.powerCalls[0].on, true)
    XCTAssertEqual(
      reply,
      String(format: "agent.homekit.controlled.on".localized, "客厅灯")
    )
  }

  func testControlRoomAppliesToAllDevices() async {
    let provider = makeProvider(devices: [livingRoomLight, bedRoomLight, airCon])
    let reply = await AgentHomeKitExecutor.execute(
      .control(target: "客厅", action: .turnOff),
      provider: provider
    )
    XCTAssertEqual(provider.powerCalls.map(\.deviceID), ["light-1", "ac-1"])
    XCTAssertTrue(provider.powerCalls.allSatisfy { $0.on == false })
    XCTAssertTrue(reply.contains("客厅灯"))
    XCTAssertTrue(reply.contains("空调"))
  }

  func testControlNotFound() async {
    let provider = makeProvider(devices: [livingRoomLight])
    let reply = await AgentHomeKitExecutor.execute(
      .control(target: "车库灯", action: .turnOn),
      provider: provider
    )
    XCTAssertTrue(provider.powerCalls.isEmpty)
    XCTAssertEqual(
      reply,
      String(format: "agent.homekit.notfound".localized, "车库灯")
    )
  }

  func testBrightenComputesRelativeBrightness() async {
    let provider = makeProvider(devices: [livingRoomLight])
    _ = await AgentHomeKitExecutor.execute(
      .control(target: "客厅灯", action: .brighten),
      provider: provider
    )
    XCTAssertEqual(provider.brightnessCalls.map(\.percent), [80])
  }

  func testBrightenWithoutCurrentUsesDefault() async {
    let provider = makeProvider(devices: [bedRoomLight])
    _ = await AgentHomeKitExecutor.execute(
      .control(target: "卧室灯", action: .brighten),
      provider: provider
    )
    XCTAssertEqual(provider.brightnessCalls.map(\.percent), [100])
  }

  func testDimClampsAtZero() async {
    let dimLight = device(id: "d1", name: "台灯", room: "书房", isOn: true, brightness: 10)
    let provider = makeProvider(devices: [dimLight])
    _ = await AgentHomeKitExecutor.execute(
      .control(target: "台灯", action: .dim),
      provider: provider
    )
    XCTAssertEqual(provider.brightnessCalls.map(\.percent), [0])
  }

  func testControlAllLights() async {
    let provider = makeProvider(devices: [livingRoomLight, bedRoomLight, airCon, frontLock])
    let reply = await AgentHomeKitExecutor.execute(
      .controlAll(category: "灯", action: .turnOff),
      provider: provider
    )
    XCTAssertEqual(provider.powerCalls.map(\.deviceID), ["light-1", "light-2"])
    XCTAssertEqual(
      reply,
      String(format: "agent.homekit.controlled.all.off".localized, 2)
    )
  }

  func testControlAllWithoutCategorySkipsLocksAndUnknown() async {
    let tv = device(id: "tv-1", name: "电视", room: "客厅", kind: .unknown)
    let provider = makeProvider(devices: [livingRoomLight, frontLock, tv])
    let reply = await AgentHomeKitExecutor.execute(
      .controlAll(category: nil, action: .turnOff),
      provider: provider
    )
    XCTAssertEqual(provider.powerCalls.map(\.deviceID), ["light-1"])
    XCTAssertEqual(
      reply,
      String(format: "agent.homekit.controlled.all.off".localized, 1)
    )
  }

  func testQuerySingleDevice() async {
    let provider = makeProvider(devices: [livingRoomLight])
    let reply = await AgentHomeKitExecutor.execute(
      .query(target: "客厅灯"),
      provider: provider
    )
    XCTAssertTrue(reply.contains("客厅灯"))
    XCTAssertTrue(reply.contains("60"))
  }

  func testQueryRoomJoinsStatuses() async {
    let provider = makeProvider(devices: [livingRoomLight, airCon])
    let reply = await AgentHomeKitExecutor.execute(
      .query(target: "客厅"),
      provider: provider
    )
    XCTAssertTrue(reply.contains("客厅灯"))
    XCTAssertTrue(reply.contains("空调"))
    XCTAssertTrue(reply.contains("；"))
  }

  func testQueryNotFound() async {
    let provider = makeProvider(devices: [livingRoomLight])
    let reply = await AgentHomeKitExecutor.execute(
      .query(target: "车库灯"),
      provider: provider
    )
    XCTAssertEqual(
      reply,
      String(format: "agent.homekit.notfound".localized, "车库灯")
    )
  }

  func testListDevicesEmptyAndNonEmpty() async {
    let empty = makeProvider(devices: [])
    let emptyReply = await AgentHomeKitExecutor.execute(.listDevices, provider: empty)
    XCTAssertEqual(emptyReply, "agent.homekit.list.empty".localized)
    let filled = makeProvider(devices: [livingRoomLight, airCon])
    let reply = await AgentHomeKitExecutor.execute(.listDevices, provider: filled)
    XCTAssertTrue(reply.contains("客厅灯"))
    XCTAssertTrue(reply.contains("空调"))
  }

  func testUnavailableAuthorization() async {
    let provider = makeProvider(devices: [livingRoomLight])
    provider.authorization = .unavailable
    let reply = await AgentHomeKitExecutor.execute(
      .control(target: "客厅灯", action: .turnOn),
      provider: provider
    )
    XCTAssertTrue(provider.powerCalls.isEmpty)
    XCTAssertEqual(reply, "agent.homekit.unavailable".localized)
  }

  func testControlFailure() async {
    let provider = makeProvider(devices: [livingRoomLight])
    provider.shouldFail = true
    let reply = await AgentHomeKitExecutor.execute(
      .control(target: "客厅灯", action: .turnOn),
      provider: provider
    )
    XCTAssertEqual(reply, "agent.homekit.control.failed".localized)
  }

  func testControlAllEmptyCategory() async {
    let provider = makeProvider(devices: [airCon])
    let reply = await AgentHomeKitExecutor.execute(
      .controlAll(category: "灯", action: .turnOff),
      provider: provider
    )
    XCTAssertTrue(provider.powerCalls.isEmpty)
    XCTAssertEqual(reply, "agent.homekit.list.empty".localized)
  }
}
