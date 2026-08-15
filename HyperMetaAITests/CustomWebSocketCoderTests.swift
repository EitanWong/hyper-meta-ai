import XCTest
@testable import HyperMetaAI

final class CustomAgentTransportConfigTests: XCTestCase {

  override func setUp() {
    super.setUp()
    CustomAgentStore.clear()
  }

  override func tearDown() {
    CustomAgentStore.clear()
    super.tearDown()
  }

  func testLegacyConfigDefaultsToHTTP() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"旧配置","baseURL":"http://192.168.1.10:8000/v1","model":"qwen"}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(CustomAgentConfig.self, from: json)
    XCTAssertEqual(config.transport, .http)
    XCTAssertTrue(config.isValid)
  }

  func testWebSocketTransportRoundTrip() throws {
    var config = CustomAgentConfig(name: "WS", baseURL: "ws://192.168.1.10:8080", model: "m")
    config.transport = .websocket
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(CustomAgentConfig.self, from: data)
    XCTAssertEqual(decoded.transport, .websocket)
  }

  func testTransportValidatesScheme() {
    var ws = CustomAgentConfig(name: "WS", baseURL: "ws://host:8080", model: "m")
    ws.transport = .websocket
    XCTAssertTrue(ws.isValid)

    ws.baseURL = "wss://host:8080"
    XCTAssertTrue(ws.isValid)

    ws.baseURL = "http://host:8080"
    XCTAssertFalse(ws.isValid, "WebSocket 协议不应接受 http 地址")

    let http = CustomAgentConfig(name: "H", baseURL: "http://host:8000/v1", model: "m")
    XCTAssertTrue(http.isValid)
  }
}

final class CustomWebSocketCoderTests: XCTestCase {

  private func decodePayload(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  func testChatPayloadShape() {
    let data = CustomWebSocketCoder.makeChatPayload(
      model: "qwen-vl",
      text: "你好",
      history: [CustomChatTurn(role: "user", text: "上一句")],
      systemPrompt: "你是助手",
      toolsJSON: ""
    )
    let payload = decodePayload(data)
    XCTAssertEqual(payload?["type"] as? String, "chat")
    XCTAssertEqual(payload?["model"] as? String, "qwen-vl")
    let messages = payload?["messages"] as? [[String: Any]]
    XCTAssertEqual(messages?.count, 3)
    XCTAssertEqual(messages?.first?["role"] as? String, "system")
    XCTAssertEqual((messages?.first?["content"] as? String), "你是助手")
    XCTAssertEqual(messages?.last?["role"] as? String, "user")
    XCTAssertEqual(messages?.last?["content"] as? String, "你好")
    XCTAssertNil(payload?["tools"], "空工具声明不应携带 tools")
  }

  func testChatPayloadWithToolsAndImage() {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    let tools = #"[{"type":"function","function":{"name":"voice.reply"}}]"#
    let data = CustomWebSocketCoder.makeChatPayload(
      model: "m",
      text: "看图",
      image: image,
      toolsJSON: tools
    )
    let payload = decodePayload(data)
    XCTAssertNotNil(payload?["tools"])
    let messages = payload?["messages"] as? [[String: Any]]
    let content = messages?.last?["content"] as? [[String: Any]]
    XCTAssertEqual(content?.count, 2)
    XCTAssertEqual(content?.first?["type"] as? String, "text")
    let imageURL = (content?.last?["image_url"] as? [String: Any])?["url"] as? String
    XCTAssertTrue(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
  }

  func testToolResultAndPongPayloads() {
    let tool = decodePayload(
      CustomWebSocketCoder.makeToolResultPayload(callID: "c1", name: "voice.reply", content: "好的")
    )
    XCTAssertEqual(tool?["type"] as? String, "tool_result")
    XCTAssertEqual(tool?["call_id"] as? String, "c1")
    XCTAssertEqual(tool?["name"] as? String, "voice.reply")
    XCTAssertEqual(tool?["content"] as? String, "好的")

    let pong = decodePayload(CustomWebSocketCoder.makePongPayload())
    XCTAssertEqual(pong?["type"] as? String, "pong")
  }

  func testParseServerEvents() {
    XCTAssertEqual(
      CustomWebSocketCoder.parseServerEvent(#"{"type":"delta","content":"你"}"#),
      .delta(content: "你")
    )
    XCTAssertEqual(
      CustomWebSocketCoder.parseServerEvent(#"{"type":"done","content":"你好"}"#),
      .done(content: "你好")
    )
    XCTAssertEqual(
      CustomWebSocketCoder.parseServerEvent(
        #"{"type":"tool_call","call_id":"c1","name":"voice.reply","arguments":"{}"}"#
      ),
      .toolCall(callID: "c1", name: "voice.reply", arguments: "{}")
    )
    XCTAssertEqual(
      CustomWebSocketCoder.parseServerEvent(#"{"type":"error","message":"boom"}"#),
      .error(message: "boom")
    )
    XCTAssertEqual(
      CustomWebSocketCoder.parseServerEvent(#"{"type":"ping"}"#),
      .ping
    )
    XCTAssertEqual(CustomWebSocketCoder.parseServerEvent("not json"), .malformed)
    XCTAssertEqual(CustomWebSocketCoder.parseServerEvent(#"{"unknown":1}"#), .malformed)
  }
}
