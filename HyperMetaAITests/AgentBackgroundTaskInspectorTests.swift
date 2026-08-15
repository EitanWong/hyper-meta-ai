/*
 * Agent Background Task Inspector Tests
 * 后台任务巡检：终态决策（完成/失败、去重、封顶、排序）、快照存储往返、
 * 设置默认值与持久化、巡检执行闭环（Mock 通知器）。
 */

import UserNotifications
import XCTest
@testable import HyperMetaAI

// MARK: - 决策

final class AgentBackgroundTaskInspectorTests: XCTestCase {
    private func task(
        _ taskId: String,
        status: QwenAgentTask.Status,
        title: String = "整理报告",
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PersistedAgentTask {
        PersistedAgentTask(
            taskId: taskId,
            title: title,
            status: status.notificationRaw,
            updatedAt: updatedAt
        )
    }

    func testEmptyTasksNothingPending() {
        XCTAssertTrue(
            AgentBackgroundTaskInspector.pendingNotifications(
                tasks: [],
                lastNotifiedTaskIDs: []
            ).isEmpty
        )
    }

    func testCompletedNotNotifiedIsPending() {
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: [task("t1", status: .completed)],
            lastNotifiedTaskIDs: []
        )
        XCTAssertEqual(pending.map(\.taskId), ["t1"])
    }

    func testFailedNotNotifiedIsPending() {
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: [task("t1", status: .failed)],
            lastNotifiedTaskIDs: []
        )
        XCTAssertEqual(pending.map(\.taskId), ["t1"])
    }

    func testAlreadyNotifiedIsSkipped() {
        XCTAssertTrue(
            AgentBackgroundTaskInspector.pendingNotifications(
                tasks: [task("t1", status: .completed)],
                lastNotifiedTaskIDs: ["t1"]
            ).isEmpty
        )
    }

    func testActiveAndCancelledNeverNotify() {
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: [
                task("w", status: .waiting),
                task("r", status: .running),
                task("c", status: .cancelled)
            ],
            lastNotifiedTaskIDs: []
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testCapAtThreeNewestFirst() {
        let tasks = [
            task("t1", status: .completed, updatedAt: Date(timeIntervalSince1970: 100)),
            task("t2", status: .completed, updatedAt: Date(timeIntervalSince1970: 200)),
            task("t3", status: .completed, updatedAt: Date(timeIntervalSince1970: 300)),
            task("t4", status: .failed, updatedAt: Date(timeIntervalSince1970: 400)),
            task("t5", status: .completed, updatedAt: Date(timeIntervalSince1970: 500))
        ]
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: tasks,
            lastNotifiedTaskIDs: []
        )
        XCTAssertEqual(pending.map(\.taskId), ["t5", "t4", "t3"])
    }

    func testNotifiedFilteredBeforeCapping() {
        let tasks = [
            task("t1", status: .completed, updatedAt: Date(timeIntervalSince1970: 100)),
            task("t2", status: .completed, updatedAt: Date(timeIntervalSince1970: 200)),
            task("t3", status: .completed, updatedAt: Date(timeIntervalSince1970: 300))
        ]
        let pending = AgentBackgroundTaskInspector.pendingNotifications(
            tasks: tasks,
            lastNotifiedTaskIDs: ["t2"]
        )
        XCTAssertEqual(pending.map(\.taskId), ["t3", "t1"])
    }

    func testNotificationTitleAndBody() {
        let done = task("t1", status: .completed, title: "整理报告")
        XCTAssertEqual(
            AgentBackgroundTaskInspector.notificationTitle(for: done),
            "agent.task.notify.done.title".localized
        )
        XCTAssertEqual(
            AgentBackgroundTaskInspector.notificationBody(for: done),
            String(format: "agent.task.notify.done.body".localized, "整理报告")
        )

        let failed = task("t2", status: .failed, title: "上传视频")
        XCTAssertEqual(
            AgentBackgroundTaskInspector.notificationTitle(for: failed),
            "agent.task.notify.failed.title".localized
        )
        XCTAssertEqual(
            AgentBackgroundTaskInspector.notificationBody(for: failed),
            String(format: "agent.task.notify.failed.body".localized, "上传视频")
        )
    }

    func testNotificationBodyFallsBackForEmptyTitle() {
        let unnamed = task("t1", status: .completed, title: "   ")
        XCTAssertEqual(
            AgentBackgroundTaskInspector.notificationBody(for: unnamed),
            String(
                format: "agent.task.notify.done.body".localized,
                "agent.task.notify.unnamed".localized
            )
        )
    }
}

// MARK: - 快照存储

final class AgentTaskNotificationStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.task.notify.store")
        defaults.removePersistentDomain(forName: "test.agent.task.notify.store")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.task.notify.store")
        defaults = nil
        super.tearDown()
    }

    private func qwenTask(
        _ taskId: String,
        status: QwenAgentTask.Status,
        title: String = "整理报告"
    ) -> QwenAgentTask {
        QwenAgentTask(
            taskId: taskId,
            title: title,
            status: status,
            resultText: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    func testSourceTextPersistsInSnapshot() {
        AgentTaskNotificationStore.save(
            [
                QwenAgentTask(
                    taskId: "s1",
                    title: "上传视频",
                    status: .failed,
                    resultText: nil,
                    sourceText: "帮我上传视频",
                    createdAt: Date(),
                    updatedAt: Date()
                )
            ],
            defaults: defaults
        )
        let loaded = AgentTaskNotificationStore.load(defaults: defaults)
        XCTAssertEqual(loaded.first?.taskId, "s1")
        XCTAssertEqual(loaded.first?.sourceText, "帮我上传视频")
        XCTAssertEqual(
            loaded.first?.status,
            QwenAgentTask.Status.failed.notificationRaw
        )
    }

    func testOldSnapshotWithoutSourceTextDecodes() {
        // 兼容旧快照：无 sourceText 键时解码为 nil
        let legacy = PersistedAgentTask(
            taskId: "s2",
            title: "整理报告",
            status: QwenAgentTask.Status.completed.notificationRaw,
            updatedAt: Date(),
            resultText: "完成"
        )
        let data = try! JSONEncoder().encode([legacy])
        defaults.set(data, forKey: AgentTaskNotificationStore.tasksKey)
        let loaded = AgentTaskNotificationStore.load(defaults: defaults)
        XCTAssertEqual(loaded.first?.sourceText, nil)
        XCTAssertEqual(loaded.first?.resultText, "完成")
    }

    func testSaveLoadRoundTrip() {
        AgentTaskNotificationStore.save(
            [qwenTask("a", status: .running), qwenTask("b", status: .completed, title: "发邮件")],
            defaults: defaults
        )
        let loaded = AgentTaskNotificationStore.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].taskId, "a")
        XCTAssertEqual(loaded[0].status, "running")
        XCTAssertFalse(loaded[0].needsNotification)
        XCTAssertEqual(loaded[1].taskId, "b")
        XCTAssertEqual(loaded[1].status, "completed")
        XCTAssertTrue(loaded[1].needsNotification)
        XCTAssertEqual(loaded[1].title, "发邮件")
        XCTAssertEqual(loaded[1].updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testSaveEmptyClearsTasks() {
        AgentTaskNotificationStore.save(
            [qwenTask("a", status: .running)],
            defaults: defaults
        )
        AgentTaskNotificationStore.save([], defaults: defaults)
        XCTAssertTrue(AgentTaskNotificationStore.load(defaults: defaults).isEmpty)
    }

    func testNotifiedIDsRoundTripDeduplicateAndCap() {
        AgentTaskNotificationStore.recordNotified(["a", "b"], defaults: defaults)
        AgentTaskNotificationStore.recordNotified(["a", "c"], defaults: defaults)
        XCTAssertEqual(
            AgentTaskNotificationStore.notifiedTaskIDs(defaults: defaults),
            ["a", "c", "b"]
        )

        let many = (0..<150).map { "id\($0)" }
        AgentTaskNotificationStore.recordNotified(many, defaults: defaults)
        let ids = AgentTaskNotificationStore.notifiedTaskIDs(defaults: defaults)
        XCTAssertEqual(ids.count, AgentTaskNotificationStore.maxNotifiedIDs)
        XCTAssertTrue(ids.contains("id149"))
        XCTAssertFalse(ids.contains("id0"))
    }

    func testLastInspectionDateNilByDefaultAndRoundTrip() {
        XCTAssertNil(AgentTaskNotificationStore.lastInspectionDate(defaults: defaults))
        let date = Date(timeIntervalSince1970: 5_000)
        AgentTaskNotificationStore.setLastInspectionDate(date, defaults: defaults)
        XCTAssertEqual(AgentTaskNotificationStore.lastInspectionDate(defaults: defaults), date)
    }
}

// MARK: - 设置

final class AgentTaskNotificationSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.task.notify.settings")
        defaults.removePersistentDomain(forName: "test.agent.task.notify.settings")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.task.notify.settings")
        defaults = nil
        super.tearDown()
    }

    func testDefaultEnabled() {
        XCTAssertTrue(AgentTaskNotificationSettings.enabled(defaults: defaults))
    }

    func testRoundTrip() {
        AgentTaskNotificationSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(AgentTaskNotificationSettings.enabled(defaults: defaults))
        AgentTaskNotificationSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(AgentTaskNotificationSettings.enabled(defaults: defaults))
    }
}

// MARK: - 巡检执行闭环

final class AgentTaskNotificationRunnerTests: XCTestCase {
    private final class MockNotifier: AgentBackgroundNotifying {
        var sent: [(title: String, body: String, level: UNNotificationInterruptionLevel, task: PersistedAgentTask)] = []
        func send(
            title: String,
            body: String,
            level: UNNotificationInterruptionLevel,
            task: PersistedAgentTask
        ) async {
            sent.append((title, body, level, task))
        }
    }

    private var defaults: UserDefaults!
    private var notifier: MockNotifier!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.task.notify.runner")
        defaults.removePersistentDomain(forName: "test.agent.task.notify.runner")
        notifier = MockNotifier()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.task.notify.runner")
        defaults = nil
        notifier = nil
        super.tearDown()
    }

    private func seed(tasks: [QwenAgentTask]) {
        AgentTaskNotificationStore.save(tasks, defaults: defaults)
    }

    func testRunNotifiesOnceAndDeduplicatesNextRun() async {
        seed(tasks: [
            QwenAgentTask(
                taskId: "a",
                title: "整理报告",
                status: .completed,
                resultText: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])
        let first = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(notifier.sent.count, 1)
        XCTAssertEqual(notifier.sent[0].title, "agent.task.notify.done.title".localized)
        XCTAssertEqual(notifier.sent[0].level, .active)
        XCTAssertEqual(notifier.sent[0].task.taskId, "a")
        XCTAssertEqual(notifier.sent[0].task.status, QwenAgentTask.Status.completed.notificationRaw)
        XCTAssertEqual(AgentTaskNotificationStore.notifiedTaskIDs(defaults: defaults), ["a"])

        let second = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(notifier.sent.count, 1)
    }

    func testRunFailedTaskUsesFailedWording() async {
        seed(tasks: [
            QwenAgentTask(
                taskId: "b",
                title: "上传视频",
                status: .failed,
                resultText: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])
        let count = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(notifier.sent[0].title, "agent.task.notify.failed.title".localized)
        XCTAssertTrue(
            notifier.sent[0].body.contains("上传视频"),
            "正文应包含任务标题"
        )
        // 失败任务通知使用普通（active）级别
        XCTAssertEqual(notifier.sent[0].level, .active)
    }

    func testRunWithNothingPendingSendsNothing() async {
        seed(tasks: [
            QwenAgentTask(
                taskId: "c",
                title: "进行中",
                status: .running,
                resultText: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])
        let count = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testRunRecordsInspectionDate() async {
        seed(tasks: [
            QwenAgentTask(
                taskId: "d",
                title: "整理报告",
                status: .completed,
                resultText: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])
        _ = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertNotNil(AgentTaskNotificationStore.lastInspectionDate(defaults: defaults))
    }
}

// MARK: - 巡检执行：通知级别传递

@MainActor
final class AgentTaskNotificationLevelTests: XCTestCase {
    private final class MockNotifier: AgentBackgroundNotifying {
        var levels: [UNNotificationInterruptionLevel] = []
        var tasks: [PersistedAgentTask] = []
        func send(
            title: String,
            body: String,
            level: UNNotificationInterruptionLevel,
            task: PersistedAgentTask
        ) async {
            levels.append(level)
            tasks.append(task)
        }
    }

    private var defaults: UserDefaults!
    private var notifier: MockNotifier!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.agent.task.notify.urgency.runner")
        defaults.removePersistentDomain(forName: "test.agent.task.notify.urgency.runner")
        notifier = MockNotifier()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.agent.task.notify.urgency.runner")
        defaults = nil
        notifier = nil
        super.tearDown()
    }

    private func seed(failed: Bool) {
        AgentTaskNotificationStore.save(
            [
                QwenAgentTask(
                    taskId: "u",
                    title: failed ? "上传视频" : "整理报告",
                    status: failed ? .failed : .completed,
                    resultText: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            ],
            defaults: defaults
        )
    }

    func testFailedTaskUsesActive() async {
        seed(failed: true)
        _ = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(notifier.levels, [.active])
        XCTAssertEqual(
            notifier.tasks.first?.status,
            QwenAgentTask.Status.failed.notificationRaw,
            "失败任务随通知传递（通知分类 / 重试载荷依据）"
        )
    }

    func testCompletedTaskUsesActive() async {
        seed(failed: false)
        _ = await AgentBackgroundTaskRunner.run(defaults: defaults, notifier: notifier)
        XCTAssertEqual(notifier.levels, [.active])
    }
}
