import Foundation
import XCTest

@testable import HyperMetaAI

final class AgentToolRegistryTests: XCTestCase {

    // MARK: - 工具注册表

    func testDefaultToolsRegisteredAndUnique() {
        let ids = AgentToolRegistry.allTools.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "工具 ID 必须唯一")
        XCTAssertEqual(
            ids,
            ["vision.capture", "message.send", "task.control", "voice.reply", "list.manage", "vision.ocr", "vision.scene", "vision.objects"]
        )
    }

    func testToolLookup() {
        XCTAssertEqual(AgentToolRegistry.tool(for: "vision.capture")?.nameKey, "agent.tool.vision.capture")
        XCTAssertNil(AgentToolRegistry.tool(for: "unknown.tool"))
    }

    func testToolsGroupedByCategory() {
        let vision = AgentToolRegistry.tools(in: .vision)
        XCTAssertEqual(vision.map(\.id), ["vision.capture", "vision.ocr", "vision.scene", "vision.objects"])
        let audio = AgentToolRegistry.tools(in: .audio)
        XCTAssertEqual(audio.map(\.id), ["voice.reply"])
        XCTAssertTrue(AgentToolRegistry.tools(in: .messaging).allSatisfy { $0.category == .messaging })
    }

    func testCanInvokeGating() {
        let vision = AgentToolRegistry.tool(for: "vision.capture")!
        let task = AgentToolRegistry.tool(for: "task.control")!
        XCTAssertTrue(vision.requiresPermission)
        XCTAssertFalse(AgentToolRegistry.canInvoke(vision, permissionGranted: false))
        XCTAssertTrue(AgentToolRegistry.canInvoke(vision, permissionGranted: true))
        XCTAssertFalse(task.requiresPermission)
        XCTAssertTrue(AgentToolRegistry.canInvoke(task, permissionGranted: false))
    }

    func testCategoryIconsNonEmpty() {
        for category in AgentToolCategory.allCases {
            XCTAssertFalse(category.iconName.isEmpty)
        }
    }

    // MARK: - 审计存储

    override func tearDown() {
        AgentAuditStore.clear()
        super.tearDown()
    }

    func testAuditAppendNewestFirst() {
        AgentAuditStore.clear()
        let first = AgentAuditStore.append(toolID: "vision.capture", action: .requested, detail: "d1")
        let second = AgentAuditStore.append(toolID: "vision.capture", action: .granted, detail: "d2")

        let entries = AgentAuditStore.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, second.id)
        XCTAssertEqual(entries[1].id, first.id)
        XCTAssertEqual(entries[0].action, .granted)
        XCTAssertEqual(entries[0].detail, "d2")
    }

    func testAuditCapsAtLimit() {
        AgentAuditStore.clear()
        for index in 0..<(AgentAuditStore.latestLimit + 5) {
            AgentAuditStore.append(toolID: "t\(index)", action: .invoked, detail: "")
        }
        let entries = AgentAuditStore.entries
        XCTAssertEqual(entries.count, AgentAuditStore.latestLimit)
        XCTAssertEqual(entries.first?.toolID, "t\(AgentAuditStore.latestLimit + 4)")
    }

    func testAuditClear() {
        AgentAuditStore.append(toolID: "vision.capture", action: .granted, detail: "")
        AgentAuditStore.clear()
        XCTAssertTrue(AgentAuditStore.entries.isEmpty)
    }

    // MARK: - 撤销策略

    func testRevokeAndRestoreRoundtrip() {
        AgentRevokeStore.restore(AgentToolRegistry.visionCapture.id)
        XCTAssertFalse(AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id))

        XCTAssertTrue(AgentRevokeStore.revoke(AgentToolRegistry.visionCapture.id))
        XCTAssertTrue(AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id))

        XCTAssertTrue(AgentRevokeStore.restore(AgentToolRegistry.visionCapture.id))
        XCTAssertFalse(AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id))
    }

    func testRevokeIsIdempotent() {
        AgentRevokeStore.restore(AgentToolRegistry.visionCapture.id)
        XCTAssertTrue(AgentRevokeStore.revoke(AgentToolRegistry.visionCapture.id))
        XCTAssertFalse(AgentRevokeStore.revoke(AgentToolRegistry.visionCapture.id), "重复撤销应返回 false")
        XCTAssertTrue(AgentRevokeStore.isRevoked(AgentToolRegistry.visionCapture.id))
        AgentRevokeStore.restore(AgentToolRegistry.visionCapture.id)
    }

    func testRevokePersistsAcrossStoreReads() {
        AgentRevokeStore.restore(AgentToolRegistry.messageSend.id)
        AgentRevokeStore.revoke(AgentToolRegistry.messageSend.id)
        XCTAssertTrue(AgentRevokeStore.isRevoked(AgentToolRegistry.messageSend.id))
        XCTAssertTrue(AgentRevokeStore.revokedToolIDs.contains(AgentToolRegistry.messageSend.id))
        AgentRevokeStore.restore(AgentToolRegistry.messageSend.id)
    }

    func testCanInvokeBlockedWhenRevoked() {
        let vision = AgentToolRegistry.tool(for: "vision.capture")!
        XCTAssertTrue(AgentToolRegistry.canInvoke(vision, permissionGranted: true))
        XCTAssertFalse(
            AgentToolRegistry.canInvoke(vision, permissionGranted: true, revoked: true),
            "已撤销的工具即使已授权也不能调用"
        )
    }

    func testRevokeStoreCleansUpInTearDown() {
        AgentRevokeStore.revoke(AgentToolRegistry.voiceReply.id)
        AgentRevokeStore.restore(AgentToolRegistry.voiceReply.id)
        XCTAssertFalse(AgentRevokeStore.isRevoked(AgentToolRegistry.voiceReply.id))
    }

    // MARK: - 视野能力策略

    func testVisionPolicyRequiresInjectionAndNotRevoked() {
        XCTAssertFalse(AgentVisionPolicy.canCapture(injectionEnabled: false, revoked: false))
        XCTAssertFalse(AgentVisionPolicy.canCapture(injectionEnabled: true, revoked: true))
        XCTAssertFalse(AgentVisionPolicy.canCapture(injectionEnabled: false, revoked: true))
        XCTAssertTrue(AgentVisionPolicy.canCapture(injectionEnabled: true, revoked: false))
    }
}

final class AgentAuditDisplayTests: XCTestCase {

    private let allActions = AgentAuditAction.allCases

    func testTitleKeysNonEmptyAndDistinct() {
        let keys = allActions.map(AgentAuditDisplayMapping.titleKey(for:))
        XCTAssertEqual(keys.count, Set(keys).count, "审计动作标题 key 必须唯一")
        for key in keys {
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(key.localized.isEmpty, "\(key) 缺少本地化文案")
        }
    }

    func testIconNamesNonEmpty() {
        for action in allActions {
            XCTAssertFalse(AgentAuditDisplayMapping.iconName(for: action).isEmpty)
        }
    }

    func testToolNameResolvesRegisteredTool() {
        let entry = AgentAuditEntry(
            id: UUID(),
            date: Date(),
            toolID: "vision.capture",
            action: .granted,
            detail: ""
        )
        let name = AgentAuditDisplayMapping.toolName(for: entry)
        XCTAssertEqual(name, "agent.tool.vision.capture".localized)
        XCTAssertFalse(name.isEmpty)
    }

    func testToolNameFallsBackForGatewayPermissionID() {
        let entry = AgentAuditEntry(
            id: UUID(),
            date: Date(),
            toolID: "auth_1",
            action: .denied,
            detail: "run_command"
        )
        let name = AgentAuditDisplayMapping.toolName(for: entry)
        XCTAssertEqual(name, "agent.audit.permission.fallback".localized)
        XCTAssertFalse(name.isEmpty)
    }
}

// MARK: - 会话审计接线

private final class AuditMockSocket: QwenGatewaySocket {
    var sentMessages: [String] = []
    private var pendingReceives: [(Result<String, Error>) -> Void] = []
    private var queuedDeliveries: [Result<String, Error>] = []

    func send(_ string: String, completion: @escaping (Error?) -> Void) {
        sentMessages.append(string)
        completion(nil)
    }

    func receive(completion: @escaping (Result<String, Error>) -> Void) {
        if queuedDeliveries.isEmpty {
            pendingReceives.append(completion)
        } else {
            completion(queuedDeliveries.removeFirst())
        }
    }

    func close() {}

    func deliver(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!
        if pendingReceives.isEmpty {
            queuedDeliveries.append(.success(text))
        } else {
            pendingReceives.removeFirst()(.success(text))
        }
    }
}

private final class AuditMockResponder: QwenPermissionResponding {
    var result: Result<QwenPermission, Error> = .failure(URLError(.badServerResponse))
    private(set) var receivedID: String?
    private(set) var receivedDecision: QwenPermissionDecision?

    func respondPermission(
        id: String,
        decision: QwenPermissionDecision
    ) async throws -> QwenPermission {
        receivedID = id
        receivedDecision = decision
        return try result.get()
    }
}

@MainActor
final class AgentSessionAuditTests: XCTestCase {
    private var socket: AuditMockSocket!
    private var gateway: QwenGatewayService!
    private var responder: AuditMockResponder!
    private var session: QwenVoiceSession!
    private var auditEntries: [AgentAuditEntry] = []

    override func setUp() {
        super.setUp()
        socket = AuditMockSocket()
        gateway = QwenGatewayService(socketFactory: { _ in self.socket })
        gateway.mode = .external
        responder = AuditMockResponder()
        session = QwenVoiceSession(gateway: gateway, permissionResponder: responder)
        session.auditSink = { [weak self] entry in
            self?.auditEntries.append(entry)
        }
    }

    override func tearDown() {
        session.stop()
        gateway.disconnect()
        session = nil
        responder = nil
        gateway = nil
        auditEntries = []
        super.tearDown()
    }

    private func pendingEvent() -> QwenPermission {
        QwenPermission(
            id: "auth_1",
            workId: "run_1",
            status: .pending,
            category: "run_command",
            summary: "run_command：需要执行 shell 命令"
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testRespondAllowWritesGrantedAudit() async {
        responder.result = .success(
            QwenPermission(id: "auth_1", workId: "run_1", status: .approved, category: "run_command", summary: "")
        )
        session.consume(.permissionRequested(taskId: "t1", permission: pendingEvent()))

        let ok = await session.respondToPermission(.allow)
        XCTAssertTrue(ok)
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(auditEntries[0].toolID, "auth_1")
        XCTAssertEqual(auditEntries[0].action, .granted)
        XCTAssertEqual(auditEntries[0].detail, "run_command：需要执行 shell 命令")
    }

    func testRespondDenyWritesDeniedAudit() async {
        responder.result = .success(
            QwenPermission(id: "auth_1", workId: "run_1", status: .denied, category: "run_command", summary: "")
        )
        session.consume(.permissionRequested(taskId: "t1", permission: pendingEvent()))

        let ok = await session.respondToPermission(.deny)
        XCTAssertTrue(ok)
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(auditEntries[0].toolID, "auth_1")
        XCTAssertEqual(auditEntries[0].action, .denied)
    }

    func testRespondFailureWritesNoAudit() async {
        session.consume(.permissionRequested(taskId: "t1", permission: pendingEvent()))

        let ok = await session.respondToPermission(.allow)
        XCTAssertFalse(ok)
        XCTAssertTrue(auditEntries.isEmpty)
    }

    func testDismissWritesLaterAudit() {
        session.consume(.permissionRequested(taskId: "t1", permission: pendingEvent()))
        session.dismissPermission()
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(auditEntries[0].toolID, "auth_1")
        XCTAssertEqual(auditEntries[0].action, .later)
    }

    func testPermissionTimeoutWritesSkippedAudit() async {
        let shortSession = QwenVoiceSession(
            gateway: gateway,
            permissionResponder: responder,
            permissionTimeout: 0.2
        )
        shortSession.auditSink = { [weak self] entry in
            self?.auditEntries.append(entry)
        }
        shortSession.consume(.permissionRequested(taskId: "t1", permission: pendingEvent()))

        await waitUntil {
            shortSession.pendingPermission == nil
        }
        XCTAssertTrue(shortSession.permissionTimedOut)
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(auditEntries[0].toolID, "auth_1")
        XCTAssertEqual(auditEntries[0].action, .skipped)
        shortSession.clearPermissionTimeout()
    }
}
