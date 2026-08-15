import Foundation
import XCTest

@testable import HyperMetaAI

final class CustomAgentStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CustomAgentStore.clear()
    }

    override func tearDown() {
        CustomAgentStore.clear()
        super.tearDown()
    }

    private func makeConfig(name: String) -> CustomAgentConfig {
        CustomAgentConfig(name: name, baseURL: "http://127.0.0.1:8000/v1", apiKey: "sk-test", model: "my-model")
    }

    func testAddAndReadBack() {
        let config = makeConfig(name: "My Agent")
        CustomAgentStore.add(config)
        XCTAssertEqual(CustomAgentStore.configs.count, 1)
        XCTAssertEqual(CustomAgentStore.config(for: config.id), config)
    }

    func testAddOverwritesSameIDAndMovesToFront() {
        let first = makeConfig(name: "A")
        let second = makeConfig(name: "B")
        CustomAgentStore.add(first)
        CustomAgentStore.add(second)
        CustomAgentStore.add(first)

        let configs = CustomAgentStore.configs
        XCTAssertEqual(configs.count, 2)
        XCTAssertEqual(configs.first?.id, first.id)
        XCTAssertEqual(configs.first?.name, "A")
    }

    func testRemoveById() {
        let config = makeConfig(name: "A")
        CustomAgentStore.add(config)
        XCTAssertTrue(CustomAgentStore.remove(id: config.id))
        XCTAssertTrue(CustomAgentStore.configs.isEmpty)
        XCTAssertFalse(CustomAgentStore.remove(id: config.id), "重复删除应返回 false")
    }

    func testRoundtripPersistsAllFields() {
        let config = CustomAgentConfig(
            name: "Local LLM",
            baseURL: "http://192.168.1.5:11434/v1",
            apiKey: "secret",
            model: "qwen3",
            toolsJSON: #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}]"#
        )
        CustomAgentStore.add(config)
        let loaded = CustomAgentStore.config(for: config.id)
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded?.baseURL, "http://192.168.1.5:11434/v1")
        XCTAssertEqual(loaded?.toolsJSON, config.toolsJSON)
    }

    func testDecodesLegacyConfigWithoutToolsJSON() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"Old","baseURL":"http://127.0.0.1:8000/v1","apiKey":"","model":"m"}
        """
        let data = Data(legacyJSON.utf8)
        let config = try JSONDecoder().decode(CustomAgentConfig.self, from: data)
        XCTAssertEqual(config.toolsJSON, "", "旧存档缺少 toolsJSON 应默认空串")
        XCTAssertEqual(config.name, "Old")
    }
}

final class CustomChatSSEParserTests: XCTestCase {

    func testParsesDataLine() {
        let result = CustomChatSSEParser.parse(line: "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}")
        XCTAssertFalse(result.isDone)
        XCTAssertEqual(result.payload, "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}")
    }

    func testIgnoresNonDataAndEmptyLines() {
        XCTAssertNil(CustomChatSSEParser.parse(line: "event: message").payload)
        XCTAssertNil(CustomChatSSEParser.parse(line: "").payload)
        XCTAssertNil(CustomChatSSEParser.parse(line: ": comment").payload)
        XCTAssertFalse(CustomChatSSEParser.parse(line: "event: message").isDone)
    }

    func testDetectsDoneMarker() {
        let result = CustomChatSSEParser.parse(line: "data: [DONE]")
        XCTAssertTrue(result.isDone)
        XCTAssertNil(result.payload)
    }

    func testTextDeltaExtraction() {
        let payload = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(CustomChatSSEParser.textDelta(from: payload), "Hello")
    }

    func testTextDeltaMissingKeysReturnsNil() {
        XCTAssertNil(CustomChatSSEParser.textDelta(from: #"{"choices":[]}"#))
        XCTAssertNil(CustomChatSSEParser.textDelta(from: #"{"foo":"bar"}"#))
        XCTAssertNil(CustomChatSSEParser.textDelta(from: "not json"))
    }

    func testToolDeltaExtractsFirstCall() {
        let payload = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]}}]}"#
        let delta = CustomChatSSEParser.toolDelta(from: payload)
        XCTAssertEqual(delta?.id, "call_1")
        XCTAssertEqual(delta?.name, "get_weather")
        XCTAssertEqual(delta?.arguments, "")
    }

    func testToolDeltaArgumentsChunkKeepsNameNil() {
        let payload = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"上海\"}"}}]}}]}"#
        let delta = CustomChatSSEParser.toolDelta(from: payload)
        XCTAssertNil(delta?.id)
        XCTAssertNil(delta?.name)
        XCTAssertEqual(delta?.arguments, #"{"city":"上海"}"#)
    }

    func testToolDeltaMissingKeysReturnsNil() {
        XCTAssertNil(CustomChatSSEParser.toolDelta(from: #"{"choices":[]}"#))
        XCTAssertNil(CustomChatSSEParser.toolDelta(from: #"{"choices":[{"delta":{"content":"hi"}}]}"#))
        XCTAssertNil(CustomChatSSEParser.toolDelta(from: "not json"))
    }
}

final class CustomAgentConfigValidationTests: XCTestCase {

    func testValidConfigRequiresHttpOrHttps() {
        let http = CustomAgentConfig(name: "Local", baseURL: "http://127.0.0.1:8000/v1", apiKey: "", model: "qwen3")
        XCTAssertTrue(http.isValid)

        let https = CustomAgentConfig(name: "Cloud", baseURL: "https://api.example.com/v1", apiKey: "k", model: "gpt")
        XCTAssertTrue(https.isValid)
    }

    func testInvalidConfigCases() {
        XCTAssertFalse(CustomAgentConfig(name: "", baseURL: "http://x/v1", apiKey: "", model: "m").isValid, "名称为空")
        XCTAssertFalse(CustomAgentConfig(name: "n", baseURL: "http://x/v1", apiKey: "", model: "").isValid, "模型为空")
        XCTAssertFalse(CustomAgentConfig(name: "n", baseURL: "ftp://x/v1", apiKey: "", model: "m").isValid, "非 http/https")
        XCTAssertFalse(CustomAgentConfig(name: "n", baseURL: "not a url", apiKey: "", model: "m").isValid, "地址非法")
        XCTAssertFalse(CustomAgentConfig(name: "n", baseURL: "", apiKey: "", model: "m").isValid, "地址为空")
    }
}

// MARK: - 服务网络层（URLProtocol mock）

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler(request)
        MockURLProtocol.lastRequest = request
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class CustomAgentServiceTests: XCTestCase {
    private var service: CustomAgentService!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        service = CustomAgentService(session: session)
    }

    override func tearDown() {
        service.cancel()
        MockURLProtocol.handler = nil
        MockURLProtocol.lastRequest = nil
        service = nil
        session = nil
        super.tearDown()
    }

    private var config: CustomAgentConfig {
        CustomAgentConfig(
            name: "Test Agent",
            baseURL: "http://127.0.0.1:8000/v1",
            apiKey: "sk-test",
            model: "test-model"
        )
    }

    func testCheckHealthMapsStatusCodes() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let healthy = await service.checkHealth(config: config)
        XCTAssertTrue(healthy)

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let unhealthy = await service.checkHealth(config: config)
        XCTAssertFalse(unhealthy)
    }

    func testSendMessageBuildsRequestAndStreamsDeltas() async throws {
        let sseBody = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: [DONE]

        """
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                XCTAssertEqual(json["model"] as? String, "test-model")
                XCTAssertEqual(json["stream"] as? Bool, true)
            } else {
                XCTFail("请求体缺失")
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }

        var deltas: [String] = []
        let completed = expectation(description: "stream completed")
        service.sendMessage(
            config: config,
            text: "你好",
            onDelta: { deltas.append($0) },
            onComplete: { text in
                XCTAssertEqual(text, "Hello world")
                completed.fulfill()
            },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(deltas, ["Hello", " world"])
    }

    func testSendMessageDeclaresToolsAndReportsProgress() async throws {
        let sseBody = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"city":"上海"}"}}]}}]}

        data: {"choices":[{"delta":{"content":"上海今天 25°C"}}]}

        data: [DONE]

        """#
        let toolsJSON = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}]"#
        var declaredTools: Any?
        MockURLProtocol.handler = { request in
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                declaredTools = json["tools"]
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }

        var tools: [String] = []
        let completed = expectation(description: "completed")
        let toolConfig = CustomAgentConfig(
            name: "Tool Agent",
            baseURL: "http://127.0.0.1:8000/v1",
            apiKey: "sk-test",
            model: "test-model",
            toolsJSON: toolsJSON
        )
        service.sendMessage(
            config: toolConfig,
            text: "天气",
            onDelta: { _ in },
            onTool: { tools.append($0) },
            onComplete: { text in
                XCTAssertEqual(text, "上海今天 25°C")
                completed.fulfill()
            },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(tools, ["get_weather"], "工具名只上报一次")
        XCTAssertNotNil(declaredTools, "请求应携带 tools 声明")
    }

    func testSendMessageOmitsInvalidToolsJSON() async throws {
        let sseBody = "data: [DONE]\n\n"
        MockURLProtocol.handler = { request in
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                XCTAssertNil(json["tools"], "非法 toolsJSON 不应进入请求")
            } else {
                XCTFail("请求体缺失")
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }
        let completed = expectation(description: "completed")
        let toolConfig = CustomAgentConfig(
            name: "Tool Agent",
            baseURL: "http://127.0.0.1:8000/v1",
            apiKey: "",
            model: "m",
            toolsJSON: "not a json array"
        )
        service.sendMessage(
            config: toolConfig,
            text: "hi",
            onDelta: { _ in },
            onComplete: { _ in completed.fulfill() },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)
    }

    func testSendMessageIncludesHistoryBeforeCurrentMessage() async throws {
        let sseBody = "data: [DONE]\n\n"
        var capturedMessages: [[String: Any]]?
        MockURLProtocol.handler = { request in
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedMessages = json["messages"] as? [[String: Any]]
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }
        let completed = expectation(description: "completed")
        let history = [
            CustomChatTurn(role: "user", text: "你好"),
            CustomChatTurn(role: "assistant", text: "你好！有什么可以帮你？")
        ]
        service.sendMessage(
            config: config,
            text: "介绍你自己",
            history: history,
            onDelta: { _ in },
            onComplete: { _ in completed.fulfill() },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)

        let messages = try XCTUnwrap(capturedMessages)
        XCTAssertEqual(messages.count, 3, "历史 2 轮 + 当前消息")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "你好")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, "你好！有什么可以帮你？")
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["content"] as? String, "介绍你自己")
    }

    func testSendMessageCapsHistoryToRecentTurns() async throws {
        let sseBody = "data: [DONE]\n\n"
        var messageCount = 0
        MockURLProtocol.handler = { request in
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let messages = json["messages"] as? [[String: Any]] {
                messageCount = messages.count
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }
        let completed = expectation(description: "completed")
        let manyTurns = (0..<25).map { index in
            CustomChatTurn(role: index.isMultiple(of: 2) ? "user" : "assistant", text: "turn \(index)")
        }
        service.sendMessage(
            config: config,
            text: "hi",
            history: manyTurns,
            onDelta: { _ in },
            onComplete: { _ in completed.fulfill() },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(messageCount, 21, "历史最多 20 轮 + 当前消息")
    }

    func testSendMessageRunsToolLoopWithLocalExecutor() async throws {
        let firstRound = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"voice.reply","arguments":""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"text\":\"你好\"}"}}]}}]}

        data: [DONE]

        """#
        let secondRound = #"""
        data: {"choices":[{"delta":{"content":"好的，已经播报"}}]}

        data: [DONE]

        """#
        var round = 0
        var secondMessages: [[String: Any]]?
        MockURLProtocol.handler = { request in
            round += 1
            if round == 2,
               let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                secondMessages = json["messages"] as? [[String: Any]]
            }
            let sse = round == 1 ? firstRound : secondRound
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }

        var executedCalls: [CustomToolCall] = []
        let completed = expectation(description: "completed")
        service.sendMessage(
            config: config,
            text: "播报",
            toolExecutor: { call in
                executedCalls.append(call)
                return "播报成功"
            },
            onDelta: { _ in },
            onComplete: { text in
                XCTAssertEqual(text, "好的，已经播报")
                completed.fulfill()
            },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(round, 2, "应经历两轮请求")
        XCTAssertEqual(executedCalls.count, 1)
        XCTAssertEqual(executedCalls.first?.id, "call_1")
        XCTAssertEqual(executedCalls.first?.name, "voice.reply")
        XCTAssertEqual(executedCalls.first?.arguments, #"{"text":"你好"}"#, "参数应跨分片累积")

        let messages = try XCTUnwrap(secondMessages)
        XCTAssertEqual(messages.count, 3, "用户消息 + assistant tool_calls + tool 结果")
        let assistant = try XCTUnwrap(messages[1] as? [String: Any])
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")
        XCTAssertEqual(toolCalls.first?["type"] as? String, "function")
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "voice.reply")
        XCTAssertEqual(function["arguments"] as? String, #"{"text":"你好"}"#)
        let toolMsg = try XCTUnwrap(messages[2] as? [String: Any])
        XCTAssertEqual(toolMsg["role"] as? String, "tool")
        XCTAssertEqual(toolMsg["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(toolMsg["content"] as? String, "播报成功")
    }

    func testSendMessageStopsAfterMaxToolRounds() async throws {
        let toolOnly = #"""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"task.control","arguments":""}}]}}]}

        data: [DONE]

        """#
        var rounds = 0
        MockURLProtocol.handler = { request in
            rounds += 1
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(toolOnly.utf8)
            )
        }
        let failed = expectation(description: "round limit")
        service.sendMessage(
            config: config,
            text: "hi",
            toolExecutor: { _ in "ok" },
            maxToolRounds: 2,
            onDelta: { _ in },
            onComplete: { _ in
                XCTFail("不应成功")
                failed.fulfill()
            },
            onError: { error in
                XCTAssertEqual(error, "custom.agent.error.toolrounds".localized)
                failed.fulfill()
            }
        )
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(rounds, 2, "应恰好请求 2 轮后停止")
    }

    func testSendMessageSurfacesServerError() async {
        let errorBody = #"{"error":{"message":"model not found"}}"#
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(errorBody.utf8)
            )
        }

        let failed = expectation(description: "error surfaced")
        service.sendMessage(
            config: config,
            text: "hi",
            onDelta: { _ in },
            onComplete: { _ in
                XCTFail("不应成功")
                failed.fulfill()
            },
            onError: { error in
                XCTAssertTrue(error.contains("model not found"), "应透出服务端错误: \(error)")
                failed.fulfill()
            }
        )
        await fulfillment(of: [failed], timeout: 5)
    }

    func testSendMessageIncludesImageContentParts() async throws {
        let sseBody = "data: [DONE]\n\n"
        MockURLProtocol.handler = { request in
            if let body = requestBodyData(from: request),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let messages = json["messages"] as? [[String: Any]],
               let content = messages.first?["content"] as? [[String: Any]] {
                XCTAssertEqual(content.count, 2, "应包含文本与图片两个 content 段")
                XCTAssertEqual(content[0]["type"] as? String, "text")
                let imageURL = (content[1]["image_url"] as? [String: Any])?["url"] as? String ?? ""
                XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"), "图片应编码为 data URL")
            } else {
                XCTFail("缺少多模态 content 数组")
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sseBody.utf8)
            )
        }

        let completed = expectation(description: "completed")
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        service.sendMessage(
            config: config,
            text: "看图",
            image: pixel,
            onDelta: { _ in },
            onComplete: { _ in completed.fulfill() },
            onError: { error in
                XCTFail("不应出错: \(error)")
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 5)
    }
}

@MainActor
final class CustomAgentLocalToolsTests: XCTestCase {

    func testStringArgumentExtraction() {
        XCTAssertEqual(
            CustomAgentLocalTools.stringArgument(from: #"{"text":"你好"}"#, key: "text"),
            "你好"
        )
        XCTAssertNil(CustomAgentLocalTools.stringArgument(from: #"{"text":""}"#, key: "text"))
        XCTAssertNil(CustomAgentLocalTools.stringArgument(from: "not json", key: "text"))
        XCTAssertNil(CustomAgentLocalTools.stringArgument(from: #"{"other":1}"#, key: "text"))
    }

    func testUnknownToolReturnsUnavailableMessage() async {
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "do_something", arguments: "{}")
        )
        XCTAssertEqual(result, "custom.agent.tool.unavailable".localized("do_something"))
    }

    func testTaskControlWithoutActiveTasksReturnsEmptyMessage() async {
        let session = QwenVoiceSession()
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "task.control", arguments: "{}"),
            context: CustomAgentToolContext(session: session)
        )
        XCTAssertEqual(result, "custom.agent.tool.taskcontrol.empty".localized)
    }

    func testListManageAddAndQuery() async {
        AgentListStore.clear()
        defer { AgentListStore.clear() }

        let addResult = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"add","list":"购物单","item":"牛奶"}"#)
        )
        XCTAssertTrue(addResult.contains("牛奶"), "添加结果应包含条目: \(addResult)")
        XCTAssertTrue(addResult.contains("购物单"), "添加结果应包含清单名: \(addResult)")

        let queryResult = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"query","list":"购物单"}"#)
        )
        XCTAssertTrue(queryResult.contains("牛奶"), "查询结果应包含条目: \(queryResult)")
        XCTAssertTrue(queryResult.contains("购物单"), "查询结果应包含清单名: \(queryResult)")
        XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["牛奶"])
    }

    func testListManageDuplicateAddReturnsDup() async {
        AgentListStore.clear()
        defer { AgentListStore.clear() }
        _ = AgentListStore.addItem("牛奶", to: "购物单")

        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"add","list":"购物单","item":"牛奶"}"#)
        )
        XCTAssertTrue(result.contains("牛奶"), "重复添加提示应包含条目: \(result)")
        XCTAssertNotEqual(result, "custom.agent.tool.unavailable".localized("list.manage"))
        XCTAssertEqual(AgentListStore.list(named: "购物单")?.items.count, 1)
    }

    func testListManageRemoveAndClear() async {
        AgentListStore.clear()
        defer { AgentListStore.clear() }
        _ = AgentListStore.addItem("牛奶", to: "购物单")
        _ = AgentListStore.addItem("鸡蛋", to: "购物单")

        let removeResult = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"remove","list":"购物单","item":"牛奶"}"#)
        )
        XCTAssertTrue(removeResult.contains("牛奶"), "删除结果应包含条目: \(removeResult)")
        XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, ["鸡蛋"])

        let clearResult = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"clear","list":"购物单"}"#)
        )
        XCTAssertTrue(clearResult.contains("购物单"), "清空结果应包含清单名: \(clearResult)")
        XCTAssertEqual(AgentListStore.list(named: "购物单")?.items, [])
    }

    func testListManageMissingParametersReturnsUsage() async {
        AgentListStore.clear()
        defer { AgentListStore.clear() }

        let noList = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"query"}"#)
        )
        XCTAssertEqual(noList, "custom.agent.tool.list.usage".localized)

        let addWithoutItem = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"add","list":"购物单"}"#)
        )
        XCTAssertEqual(addWithoutItem, "custom.agent.tool.list.usage".localized)

        let unknownAction = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "list.manage", arguments: #"{"action":"rename","list":"购物单"}"#)
        )
        XCTAssertEqual(unknownAction, "custom.agent.tool.list.usage".localized)
        XCTAssertTrue(AgentListStore.lists.isEmpty, "非法调用不应改动存储")
    }

    func testVisionCaptureApprovedThenCapturesAndWritesAudit() async {
        AgentAuditStore.clear()
        defer { AgentAuditStore.clear() }

        var captured = false
        let context = CustomAgentToolContext(
            captureVision: {
                captured = true
                return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            },
            requestApproval: { _ in .allowed }
        )
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "vision.capture", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(result, "custom.agent.tool.vision.done".localized)
        XCTAssertTrue(captured, "批准后应执行拍照")

        let actions = AgentAuditStore.entries.map(\.action)
        XCTAssertTrue(actions.contains(.requested))
        XCTAssertTrue(actions.contains(.granted))
    }

    func testVisionCaptureDeniedSkipsCaptureAndWritesAudit() async {
        AgentAuditStore.clear()
        defer { AgentAuditStore.clear() }

        var captured = false
        let context = CustomAgentToolContext(
            captureVision: {
                captured = true
                return nil
            },
            requestApproval: { _ in .denied }
        )
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "vision.capture", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(result, "custom.agent.tool.denied".localized)
        XCTAssertFalse(captured, "拒绝后不应拍照")

        let actions = AgentAuditStore.entries.map(\.action)
        XCTAssertTrue(actions.contains(.denied))
    }

    func testVisionCaptureRevokedIsIntercepted() async {
        AgentRevokeStore.revoke(AgentToolRegistry.visionCapture.id)
        defer { AgentRevokeStore.restore(AgentToolRegistry.visionCapture.id) }

        let context = CustomAgentToolContext(requestApproval: { _ in .allowed })
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "vision.capture", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(result, "custom.agent.tool.revoked".localized, "撤销中的工具即使有审批也不执行")
    }

    func testVisionCaptureWithoutFrameReturnsNoFrame() async {
        let context = CustomAgentToolContext(
            captureVision: { nil },
            requestApproval: { _ in .allowed }
        )
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "vision.capture", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(result, "custom.agent.tool.vision.noframe".localized)
    }

    func testApproverTimesOutWithoutDecision() async {
        let decision = await CustomAgentToolApprover.request(summary: "test", timeout: 0.1)
        XCTAssertEqual(decision, .timedOut)
    }

    func testVisionCaptureTimeoutWritesSkippedAudit() async {
        AgentAuditStore.clear()
        defer { AgentAuditStore.clear() }

        let context = CustomAgentToolContext(requestApproval: { summary in
            await CustomAgentToolApprover.request(summary: summary, timeout: 0.1)
        })
        let result = await CustomAgentLocalTools.execute(
            CustomToolCall(id: "c", name: "vision.capture", arguments: "{}"),
            context: context
        )
        XCTAssertEqual(result, "custom.agent.tool.timedout".localized)
        let actions = AgentAuditStore.entries.map(\.action)
        XCTAssertTrue(actions.contains(.requested))
        XCTAssertTrue(actions.contains(.skipped))
    }
}

/// URLProtocol 收到的请求体可能只在 httpBodyStream 中
private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
