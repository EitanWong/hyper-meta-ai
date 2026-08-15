import XCTest
@testable import HyperMetaAI

final class AgentDisplayMenuTests: XCTestCase {

    func testVoiceMenuActions() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice),
            [.home, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testChatMenuActions() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat),
            [.home, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testAllMenuIconsAreValidDisplayIcons() {
        for action in AgentDisplayAction.allCases {
            XCTAssertTrue(
                AgentDisplayMenuMapping.isValidIcon(for: action),
                "\(action.rawValue) 的图标不在 MWDATDisplay 图标目录中"
            )
        }
    }

    func testAllMenuTitlesAreNonEmpty() {
        for action in AgentDisplayAction.allCases {
            XCTAssertFalse(AgentDisplayMenuMapping.title(for: action).isEmpty)
        }
    }

    func testMenuActionsAreStable() {
        XCTAssertEqual(AgentDisplayMenuMapping.actions(for: .voice), AgentDisplayMenuMapping.actions(for: .voice))
        XCTAssertEqual(AgentDisplayMenuMapping.actions(for: .chat), AgentDisplayMenuMapping.actions(for: .chat))
    }

    func testAnnounceTasksHiddenWithoutActiveTasks() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.announceTasks))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.announceTasks))
    }

    func testAnnounceTasksShownWithActiveTasks() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasActiveTasks: true),
            [.home, .announceTasks, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasActiveTasks: true),
            [.home, .announceTasks, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testFollowUpHiddenWithoutResultContext() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.followUp))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.followUp))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(for: .voice, hasActiveTasks: true).contains(.followUp)
        )
    }

    func testFollowUpShownWithResultContext() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasFollowUpContext: true),
            [.home, .followUp, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasFollowUpContext: true),
            [.home, .followUp, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testFollowUpOrderedAfterTaskWithActiveTasks() {
        let actions = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasFollowUpContext: true
        )
        XCTAssertEqual(
            actions,
            [.home, .announceTasks, .followUp, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testFollowUpActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .followUp), "Ask")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .followUp), "three_dot_speech_bubble")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .followUp))
    }

    func testRemindersHiddenWithoutActiveReminders() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.reminders))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.reminders))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(for: .voice, hasActiveTasks: true, hasFollowUpContext: true)
                .contains(.reminders)
        )
    }

    func testRemindersShownWithActiveReminders() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasActiveReminders: true),
            [.home, .reminders, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasActiveReminders: true),
            [.home, .reminders, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testRemindersOrderedAfterTaskAndAsk() {
        let actions = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasFollowUpContext: true,
            hasActiveReminders: true
        )
        XCTAssertEqual(
            actions,
            [.home, .announceTasks, .followUp, .reminders, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testRemindersActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .reminders), "Reminders")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .reminders), "bell")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .reminders))
    }

    func testTodayOverviewTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .todayOverview), "Today")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .todayOverview), "clock")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .todayOverview))
    }

    func testTodayOverviewHiddenWithoutContent() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.todayOverview))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.todayOverview))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(for: .voice, hasActiveTasks: true).contains(.todayOverview),
            "任务单项不触发 Today（Today 需要日程 / 提醒 / 任务任一内容，且由调用方聚合）"
        )
    }

    func testTodayOverviewShownWithContent() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasTodayOverview: true),
            [.home, .todayOverview, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        let withAll = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasTodayOverview: true,
            hasFollowUpContext: true,
            hasActiveReminders: true
        )
        XCTAssertEqual(
            withAll,
            [.home, .announceTasks, .todayOverview, .followUp, .reminders, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss],
            "Today 排在 Task 之后、Ask 之前"
        )
    }

    func testTomorrowOverviewTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .tomorrowOverview), "Tomorrow")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .tomorrowOverview), "arrow_right")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .tomorrowOverview))
    }

    func testTomorrowOverviewHiddenWithoutContent() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.tomorrowOverview))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.tomorrowOverview))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(
                for: .voice,
                hasActiveTasks: true,
                hasTodayOverview: true
            ).contains(.tomorrowOverview),
            "仅 Today 内容不触发 Tomorrow（由调用方分别聚合）"
        )
    }

    func testTomorrowOverviewShownWithContent() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(
                for: .voice,
                hasTodayOverview: true,
                hasTomorrowOverview: true
            ),
            [.home, .todayOverview, .tomorrowOverview, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss],
            "Tomorrow 排在 Today 之后"
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasTomorrowOverview: true),
            [.home, .tomorrowOverview, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testCalendarHiddenWithoutUpcomingEvents() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.calendar))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.calendar))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(
                for: .voice,
                hasActiveTasks: true,
                hasFollowUpContext: true,
                hasActiveReminders: true
            ).contains(.calendar)
        )
    }

    func testCalendarShownWithUpcomingEvents() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasUpcomingCalendarEvents: true),
            [.home, .calendar, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasUpcomingCalendarEvents: true),
            [.home, .calendar, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testCalendarOrderedAfterRemindersBeforePrefs() {
        let actions = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasFollowUpContext: true,
            hasActiveReminders: true,
            hasUpcomingCalendarEvents: true,
            hasAgentPrefs: true,
            hasNamedLists: true
        )
        XCTAssertEqual(
            actions,
            [.home, .announceTasks, .followUp, .reminders, .calendar, .prefs, .lists, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testCalendarActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .calendar), "Calendar")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .calendar), "calendar")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .calendar))
    }

    func testPrefsHiddenWithoutMemoryOrRules() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.prefs))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.prefs))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(
                for: .voice,
                hasActiveTasks: true,
                hasFollowUpContext: true,
                hasActiveReminders: true
            ).contains(.prefs)
        )
    }

    func testPrefsShownWithMemoryOrRules() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasAgentPrefs: true),
            [.home, .prefs, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasAgentPrefs: true),
            [.home, .prefs, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testPrefsOrderedAfterAllDynamicItems() {
        let actions = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasFollowUpContext: true,
            hasActiveReminders: true,
            hasAgentPrefs: true
        )
        XCTAssertEqual(
            actions,
            [.home, .announceTasks, .followUp, .reminders, .prefs, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testPrefsActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .prefs), "Prefs")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .prefs), "sliders_horizontal")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .prefs))
    }

    func testListsHiddenWithoutNamedLists() {
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .voice).contains(.lists))
        XCTAssertFalse(AgentDisplayMenuMapping.actions(for: .chat).contains(.lists))
        XCTAssertFalse(
            AgentDisplayMenuMapping.actions(
                for: .voice,
                hasActiveTasks: true,
                hasFollowUpContext: true,
                hasActiveReminders: true,
                hasAgentPrefs: true
            ).contains(.lists)
        )
    }

    func testListsShownWithNamedLists() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .voice, hasNamedLists: true),
            [.home, .lists, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .chat, hasNamedLists: true),
            [.home, .lists, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .newChat, .dismiss]
        )
    }

    func testListsOrderedAfterAllDynamicItems() {
        let actions = AgentDisplayMenuMapping.actions(
            for: .voice,
            hasActiveTasks: true,
            hasFollowUpContext: true,
            hasActiveReminders: true,
            hasAgentPrefs: true,
            hasNamedLists: true
        )
        XCTAssertEqual(
            actions,
            [.home, .announceTasks, .followUp, .reminders, .prefs, .lists, .wake, .repeatLastReply, .audit, .shortcuts, .ocr, .translate, .scene, .captureVision, .newChat, .dismiss]
        )
    }

    func testListsActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .lists), "Lists")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .lists), "shopping_bag")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .lists))
    }

    func testAuditActionTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .audit), "Audit")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .audit), "three_horizontal_lines")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .audit))
    }

    func testAnnounceTasksTitleAndIcon() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .announceTasks), "Task")
        XCTAssertEqual(AgentDisplayMenuMapping.iconName(for: .announceTasks), "gear")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .announceTasks))
    }

    func testTaskCenterMenuActions() {
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .taskCenter),
            [.taskProgress, .cancelLatestTask, .backToMainMenu]
        )
        XCTAssertEqual(
            AgentDisplayMenuMapping.actions(for: .taskCenter, hasFailedTasks: true),
            [.taskProgress, .cancelLatestTask, .retryLatestTask, .backToMainMenu]
        )
    }

    func testTaskCenterTitles() {
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .taskProgress), "Progress")
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .cancelLatestTask), "Cancel")
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .retryLatestTask), "Retry")
        XCTAssertEqual(AgentDisplayMenuMapping.title(for: .backToMainMenu), "Back")
        XCTAssertTrue(AgentDisplayMenuMapping.isValidIcon(for: .retryLatestTask))
    }
}

final class AgentGlassesAuditMappingTests: XCTestCase {

    func testAllGlassesIconsAreValidDisplayIcons() {
        for action in AgentAuditAction.allCases {
            XCTAssertTrue(
                AgentAuditDisplayMapping.isValidGlassesIcon(for: action),
                "\(action.rawValue) 的镜片图标不在 MWDATDisplay 图标目录中"
            )
        }
    }

    func testResultContentWithDetail() {
        let entry = AgentAuditEntry(
            id: UUID(),
            date: Date().addingTimeInterval(-120),
            toolID: "vision.capture",
            action: .granted,
            detail: "run_command"
        )
        let content = AgentAuditDisplayMapping.resultContent(for: entry)
        XCTAssertTrue(content.title.contains("agent.tool.vision.capture".localized))
        XCTAssertTrue(content.title.contains("agent.audit.action.granted".localized))
        XCTAssertTrue(content.text.hasPrefix("run_command"))
        XCTAssertTrue(content.text.contains("agent.task.time.minutes".localized(2)))
    }

    func testResultContentWithoutDetailUsesTimeOnly() {
        let entry = AgentAuditEntry(
            id: UUID(),
            date: Date(),
            toolID: "auth_1",
            action: .skipped,
            detail: ""
        )
        let content = AgentAuditDisplayMapping.resultContent(for: entry)
        XCTAssertTrue(content.title.contains("agent.audit.permission.fallback".localized))
        XCTAssertEqual(content.text, "agent.task.time.justnow".localized)
    }
}


// MARK: - 动态选择卡（镜片按钮选择）映射

final class AgentDisplayChoiceMappingTests: XCTestCase {
    func testOptionLabelNumbering() {
        XCTAssertEqual(
            AgentDisplayChoiceMapping.optionLabel(index: 0, title: "产品评审"),
            "1. 产品评审"
        )
        XCTAssertEqual(
            AgentDisplayChoiceMapping.optionLabel(index: 2, title: "技术评审"),
            "3. 技术评审"
        )
    }

    func testOptionLabelTruncatesLongTitle() {
        let long = String(repeating: "很长的日程标题", count: 5) // 25 字符
        let label = AgentDisplayChoiceMapping.optionLabel(index: 0, title: long)
        XCTAssertTrue(label.hasPrefix("1. "))
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertLessThanOrEqual(label.count, 3 + AgentDisplayChoiceMapping.maxOptionLength + 1)
    }

    func testOptionLabelTrimsWhitespace() {
        XCTAssertEqual(
            AgentDisplayChoiceMapping.optionLabel(index: 1, title: "  会议  "),
            "2. 会议"
        )
    }

    func testOptionLabelEmptyTitleKeepsNumber() {
        XCTAssertEqual(AgentDisplayChoiceMapping.optionLabel(index: 0, title: ""), "1. ")
    }

    func testCancelLabel() {
        XCTAssertEqual(AgentDisplayChoiceMapping.cancelLabel(), "Cancel")
    }

    func testDeleteLabel() {
        XCTAssertEqual(AgentDisplayChoiceMapping.deleteLabel(), "Delete")
    }

    func testCompleteLabel() {
        XCTAssertEqual(AgentDisplayChoiceMapping.completeLabel(), "Done")
    }
}

// MARK: - 镜片今日总览文案

@MainActor
final class AgentTodayOverviewBuilderTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
  }

  override func tearDown() {
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func event(_ title: String, hourOffset: TimeInterval) -> AgentCalendarEvent {
    let start = now.addingTimeInterval(hourOffset * 3600)
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testFullOverview() {
    let content = AgentTodayOverviewBuilder.content(
      events: [event("产品评审", hourOffset: 2)],
      reminders: [AgentReminder(text: "喝水", fireDate: now.addingTimeInterval(600))],
      taskTitles: ["上传视频", "  "],
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.scheduleLine?.contains("产品评审") == true)
    XCTAssertTrue(content.reminderLine?.contains("喝水") == true)
    XCTAssertEqual(content.taskLine, "进行中任务 1 项")
    XCTAssertTrue(content.fullText.contains("产品评审"))
    XCTAssertTrue(content.fullText.contains("喝水"))
    XCTAssertTrue(content.fullText.contains("进行中任务 1 项"))
  }

  func testEmptyOverviewFallsBack() {
    let content = AgentTodayOverviewBuilder.content(
      events: [],
      reminders: [],
      taskTitles: [],
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.isEmpty)
    XCTAssertEqual(content.fullText, "一切就绪，暂无安排。")
  }

  func testSingleLineOverview() {
    let content = AgentTodayOverviewBuilder.content(
      events: [],
      reminders: [AgentReminder(text: "吃药", fireDate: now.addingTimeInterval(1800))],
      taskTitles: [],
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.scheduleLine == nil)
    XCTAssertTrue(content.taskLine == nil)
    XCTAssertTrue(content.reminderLine?.contains("吃药") == true)
  }
}


@MainActor
final class AgentTomorrowOverviewBuilderTests: XCTestCase {
  private var previousLanguage: AppLanguage = .system
  private let now = Date(timeIntervalSince1970: 1_772_884_800) // 2026-03-07 12:00:00 UTC
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  override func setUp() {
    super.setUp()
    previousLanguage = LanguageManager.shared.currentLanguage
    LanguageManager.shared.currentLanguage = .chinese
  }

  override func tearDown() {
    LanguageManager.shared.currentLanguage = previousLanguage
    super.tearDown()
  }

  private func event(_ title: String, hourOffset: TimeInterval) -> AgentCalendarEvent {
    let start = now.addingTimeInterval(24 * 3600 + hourOffset * 3600) // 明天
    return AgentCalendarEvent(title: title, start: start, end: start.addingTimeInterval(3600))
  }

  func testSingleEventOverview() {
    let content = AgentTomorrowOverviewBuilder.content(
      events: [event("产品评审", hourOffset: 2)],
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.scheduleLine?.contains("明天") == true)
    XCTAssertTrue(content.scheduleLine?.contains("产品评审") == true)
    XCTAssertNil(content.countLine)
    XCTAssertTrue(content.fullText.contains("产品评审"))
  }

  func testMultipleEventsIncludeCount() {
    let content = AgentTomorrowOverviewBuilder.content(
      events: [event("评审", hourOffset: 1), event("出游", hourOffset: 3)],
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.countLine?.contains("2") == true)
    XCTAssertTrue(content.fullText.contains("明天共 2 场日程"))
  }

  func testEmptyOverviewFallsBack() {
    let content = AgentTomorrowOverviewBuilder.content(
      events: [],
      now: now,
      calendar: calendar
    )
    XCTAssertTrue(content.isEmpty)
    XCTAssertEqual(content.fullText, "明天暂无安排。")
  }

  func testAllDayEventOverview() {
    let start = now.addingTimeInterval(24 * 3600)
    let allDay = AgentCalendarEvent(
      title: "出游",
      start: start,
      end: start.addingTimeInterval(86400),
      isAllDay: true
    )
    let content = AgentTomorrowOverviewBuilder.content(
      events: [allDay],
      now: now,
      calendar: calendar
    )
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.fullText.contains("出游"))
    XCTAssertNil(content.countLine)
  }
}


final class AgentTaskChoiceFlowTests: XCTestCase {
  private func task(id: String, title: String, status: QwenAgentTask.Status = .running) -> QwenAgentTask {
    QwenAgentTask(
      taskId: id,
      title: title,
      status: status,
      resultText: nil,
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 200)
    )
  }

  func testPresentationByTaskCount() {
    XCTAssertEqual(AgentTaskChoiceFlow.presentation(taskCount: 0), .none)
    XCTAssertEqual(AgentTaskChoiceFlow.presentation(taskCount: 1), .direct)
    XCTAssertEqual(AgentTaskChoiceFlow.presentation(taskCount: 2), .choose)
    XCTAssertEqual(AgentTaskChoiceFlow.presentation(taskCount: 6), .choose)
  }

  func testOptionLabelsKeepOriginalIndex() {
    let tasks = [
      task(id: "t1", title: "上传视频"),
      task(id: "t2", title: "整理报告"),
      task(id: "t3", title: "写周报")
    ]
    XCTAssertEqual(
      AgentTaskChoiceFlow.optionLabels(from: tasks),
      ["1. 上传视频", "2. 整理报告", "3. 写周报"]
    )
  }

  func testOptionLabelsCapAtMax() {
    let tasks = (0..<8).map { i in
      task(id: "t\(i)", title: "任务\(i + 1)")
    }
    let labels = AgentTaskChoiceFlow.optionLabels(from: tasks)
    XCTAssertEqual(labels.count, AgentTaskChoiceFlow.maxOptions)
    XCTAssertEqual(labels.first, "1. 任务1")
    XCTAssertEqual(labels.last, "5. 任务5")
    XCTAssertTrue(labels.contains("4. 任务4"))
    XCTAssertFalse(labels.contains("6. 任务6"))
  }

  func testOptionLabelTruncatesLongTitle() {
    let long = task(id: "t1", title: "这是一个非常非常长的任务标题")
    let labels = AgentTaskChoiceFlow.optionLabels(from: [long])
    XCTAssertTrue(labels.first?.hasPrefix("1. ") == true)
    XCTAssertTrue(labels.first?.hasSuffix("…") == true)
  }

  func testOptionLabelBlankTitleKeepsNumber() {
    let blank = task(id: "t1", title: "  ")
    XCTAssertEqual(AgentTaskChoiceFlow.optionLabels(from: [blank]), ["1. "])
  }
}
