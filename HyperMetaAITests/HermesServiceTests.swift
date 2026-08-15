import Foundation
import XCTest

@testable import HyperMetaAI

final class HermesModelsTests: XCTestCase {
  func testPlainTextRequestEncoding() throws {
    let request = HermesResponsesRequest.plainText("hello", model: "hermes-agent", conversation: "test")
    let data = try JSONEncoder().encode(request)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(json["model"] as? String, "hermes-agent")
    XCTAssertEqual(json["input"] as? String, "hello")
    XCTAssertEqual(json["conversation"] as? String, "test")
    XCTAssertEqual(json["stream"] as? Bool, true)
  }

  func testImageRequestEncoding() throws {
    let request = HermesResponsesRequest.withImage(
      "what is this",
      jpegBase64: "AAAA",
      model: "hermes-agent",
      conversation: "test"
    )
    let data = try JSONEncoder().encode(request)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try XCTUnwrap(json["input"] as? [[String: Any]])
    let item = try XCTUnwrap(items.first)
    let content = try XCTUnwrap(item["content"] as? [[String: Any]])

    XCTAssertEqual(item["role"] as? String, "user")
    XCTAssertEqual(content.count, 2)
    XCTAssertEqual(content[0]["type"] as? String, "input_text")
    XCTAssertEqual(content[0]["text"] as? String, "what is this")
    XCTAssertEqual(content[1]["type"] as? String, "input_image")
    XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64,AAAA")
  }

  func testSSEParserHandlesEventHeaderStyle() {
    var buffer = ""
    let chunk = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Hello"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"r1","output":[{"type":"message","content":[{"type":"output_text","text":"Hello world"}]}]}}

    """
    let events = HermesSSEParser.parse(chunk: chunk, into: &buffer)

    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].type, "response.output_text.delta")
    XCTAssertEqual(events[0].textDelta, "Hello")
    XCTAssertEqual(events[1].type, "response.completed")
  }

  func testSSEParserHandlesPartialChunksAcrossFrames() {
    var buffer = ""
    var events = HermesSSEParser.parse(
      chunk: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hel",
      into: &buffer
    )
    XCTAssertTrue(events.isEmpty)
    XCTAssertFalse(buffer.isEmpty)

    events = HermesSSEParser.parse(chunk: "lo\"}\n\n", into: &buffer)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].textDelta, "Hello")
    XCTAssertTrue(buffer.isEmpty)
  }

  func testSSEParserIgnoresDoneMarker() {
    var buffer = ""
    let chunk = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\ndata: [DONE]\n\n"
    let events = HermesSSEParser.parse(chunk: chunk, into: &buffer)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].textDelta, "x")
  }

  func testAccumulatorCollectsDeltas() {
    var accumulator = HermesStreamAccumulator()
    accumulator.apply(HermesSSEEvent(type: "response.output_text.delta", json: ["delta": "Hi"]))
    accumulator.apply(HermesSSEEvent(type: "response.output_text.delta", json: ["delta": " there"]))
    XCTAssertEqual(accumulator.text, "Hi there")
  }

  func testAccumulatorCapturesFunctionCallTool() {
    var accumulator = HermesStreamAccumulator()
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.added",
      json: ["type": "function_call", "name": "terminal", "arguments": "{\"command\":\"ls\"}"]
    ))
    XCTAssertEqual(accumulator.toolName, "terminal")
  }

  func testAccumulatorCapturesNestedFunctionCall() {
    var accumulator = HermesStreamAccumulator()
    let item: [String: Any] = [
      "id": "fc_1", "type": "function_call", "status": "in_progress",
      "name": "web_search", "call_id": "call_1", "arguments": "{\"query\":\"weather\"}"
    ]
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.added",
      json: ["type": "response.output_item.added", "output_index": 0, "item": item]
    ))

    XCTAssertEqual(accumulator.toolName, "web_search")
    XCTAssertEqual(accumulator.toolCalls.count, 1)
    XCTAssertEqual(accumulator.toolCalls[0].callID, "call_1")
    XCTAssertEqual(accumulator.toolCalls[0].name, "web_search")
    XCTAssertEqual(accumulator.toolCalls[0].arguments, "{\"query\":\"weather\"}")
  }

  func testAccumulatorDeduplicatesFunctionCallAcrossAddedAndDone() {
    var accumulator = HermesStreamAccumulator()
    let started: [String: Any] = [
      "id": "fc_1", "type": "function_call", "status": "in_progress",
      "name": "terminal", "call_id": "call_1", "arguments": "{\"command\":\"ls\"}"
    ]
    let done: [String: Any] = [
      "id": "fc_1", "type": "function_call", "status": "completed",
      "name": "terminal", "call_id": "call_1", "arguments": "{\"command\":\"ls\"}"
    ]
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.added",
      json: ["type": "response.output_item.added", "item": started]
    ))
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.done",
      json: ["type": "response.output_item.done", "item": done]
    ))
    XCTAssertEqual(accumulator.toolCalls.count, 1, "同一 call 的 added/done 只记录一次")
  }

  func testAccumulatorCapturesFunctionCallOutput() {
    var accumulator = HermesStreamAccumulator()
    let outputItem: [String: Any] = [
      "id": "fco_1", "type": "function_call_output", "call_id": "call_1",
      "output": [["type": "input_text", "text": "README.md src/"]], "status": "completed"
    ]
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.added",
      json: ["type": "response.output_item.added", "item": outputItem]
    ))
    // 同一结果的 done 事件不应重复
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.done",
      json: ["type": "response.output_item.done", "item": outputItem]
    ))

    XCTAssertEqual(accumulator.toolResults.count, 1)
    XCTAssertEqual(accumulator.toolResults[0].callID, "call_1")
    XCTAssertEqual(accumulator.toolResults[0].output, "README.md src/")

    accumulator.clearToolResults()
    XCTAssertTrue(accumulator.toolResults.isEmpty)
  }

  func testAccumulatorCapturesFlatFunctionCallOutputString() {
    var accumulator = HermesStreamAccumulator()
    accumulator.apply(HermesSSEEvent(
      type: "response.output_item.done",
      json: ["type": "function_call_output", "call_id": "call_2", "output": "plain result"]
    ))
    XCTAssertEqual(accumulator.toolResults.count, 1)
    XCTAssertEqual(accumulator.toolResults[0].output, "plain result")
  }

  func testAccumulatorCapturesHermesToolProgress() {
    var accumulator = HermesStreamAccumulator()
    accumulator.apply(HermesSSEEvent(
      type: "hermes.tool.progress",
      json: ["type": "hermes.tool.progress", "tool": "web_search", "status": "start"]
    ))
    XCTAssertEqual(accumulator.toolName, "web_search")
  }

  func testAccumulatorUsesCompletionPayloadText() {
    var accumulator = HermesStreamAccumulator()
    accumulator.apply(HermesSSEEvent(type: "response.output_text.delta", json: ["delta": "partial"]))
    let response: [String: Any] = [
      "id": "r1",
      "output": [
        ["type": "message", "content": [["type": "output_text", "text": "final answer"]]]
      ]
    ]
    accumulator.apply(HermesSSEEvent(type: "response.completed", json: ["response": response]))
    XCTAssertEqual(accumulator.text, "final answer")
  }

  func testFailedEventExposesServerError() {
    let event = HermesSSEEvent(
      type: "response.failed",
      json: ["type": "response.failed", "response": ["error": ["code": "500", "message": "boom"]]]
    )
    XCTAssertTrue(event.isError)
    XCTAssertEqual(event.errorMessage, "boom")
  }

  func testNonStreamingResponseAssembly() throws {
    let body = """
    {"id":"resp_1","status":"completed","output":[
      {"type":"function_call","name":"terminal","status":"completed","call_id":"call_1","arguments":"{\\"command\\":\\"ls\\"}"},
      {"type":"function_call_output","status":"completed","call_id":"call_1","output":"README.md"},
      {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Your project has README.md"}]}
    ]}
    """
    let response = try JSONDecoder().decode(HermesResponsesResponse.self, from: Data(body.utf8))
    XCTAssertEqual(response.assembledText, "Your project has README.md")
  }

  func testNonStreamingResponseParsesToolCallsAndResults() throws {
    let body = """
    {"id":"resp_1","status":"completed","output":[
      {"type":"function_call","name":"web_search","status":"completed","call_id":"call_9","arguments":"{\\"query\\":\\"weather\\"}"},
      {"type":"function_call_output","status":"completed","call_id":"call_9","output":"sunny 26C"},
      {"type":"message","role":"assistant","content":[{"type":"output_text","text":"It is sunny"}]}
    ]}
    """
    let response = try JSONDecoder().decode(HermesResponsesResponse.self, from: Data(body.utf8))

    XCTAssertEqual(response.toolCalls.count, 1)
    XCTAssertEqual(response.toolCalls[0].callID, "call_9")
    XCTAssertEqual(response.toolCalls[0].name, "web_search")
    XCTAssertEqual(response.toolCalls[0].arguments, "{\"query\":\"weather\"}")

    XCTAssertEqual(response.toolResults.count, 1)
    XCTAssertEqual(response.toolResults[0].callID, "call_9")
    XCTAssertEqual(response.toolResults[0].output, "sunny 26C")
  }

  func testHermesToolOutputDecodesPartsArray() throws {
    let body = """
    {"id":"resp_1","status":"completed","output":[
      {"type":"function_call_output","status":"completed","call_id":"call_1","output":[{"type":"input_text","text":"line one"},{"type":"input_text","text":"line two"}]}
    ]}
    """
    let response = try JSONDecoder().decode(HermesResponsesResponse.self, from: Data(body.utf8))
    XCTAssertEqual(response.toolResults.count, 1)
    XCTAssertEqual(response.toolResults[0].output, "line one\nline two")
  }
}

@MainActor
final class AgentNewChatTests: XCTestCase {

  func testHermesStartNewConversationRotatesAndPersists() {
    let service = HermesService.shared
    let original = service.conversationName
    defer {
      service.conversationName = original
      service.saveSettings()
    }

    service.startNewConversation()

    XCTAssertNotEqual(service.conversationName, original)
    XCTAssertTrue(service.conversationName.hasPrefix("hyper-meta-ios-"))
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: "hermes_conversation"),
      service.conversationName
    )
  }

  func testOpenClawStartNewChatRotatesAndPersists() {
    let service = OpenClawNodeService.shared
    let original = service.chatSessionKey
    defer {
      service.chatSessionKey = original
      UserDefaults.standard.set(original, forKey: "openclaw_chat_session")
    }

    service.startNewChat()

    XCTAssertNotEqual(service.chatSessionKey, original)
    XCTAssertTrue(service.chatSessionKey.hasPrefix("turbometa-"))
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: "openclaw_chat_session"),
      service.chatSessionKey
    )
  }
}
