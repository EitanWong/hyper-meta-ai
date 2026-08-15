import XCTest
@testable import HyperMetaAI

final class AgentDisplayPermissionTests: XCTestCase {

    func testPermissionActionsAreStable() {
        XCTAssertEqual(AgentDisplayPermissionAction.allCases, [.allow, .deny, .later])
    }

    func testPermissionTitlesAndIcons() {
        XCTAssertEqual(AgentDisplayPermissionMapping.title(for: .allow), "Allow")
        XCTAssertEqual(AgentDisplayPermissionMapping.title(for: .deny), "Deny")
        XCTAssertEqual(AgentDisplayPermissionMapping.title(for: .later), "Later")
        XCTAssertEqual(AgentDisplayPermissionMapping.iconName(for: .allow), "checkmark")
        XCTAssertEqual(AgentDisplayPermissionMapping.iconName(for: .deny), "x")
        XCTAssertEqual(AgentDisplayPermissionMapping.iconName(for: .later), "clock")
    }

    func testPermissionIconsAreValidDisplayIcons() {
        for action in AgentDisplayPermissionAction.allCases {
            XCTAssertTrue(
                AgentDisplayPermissionMapping.isValidIcon(for: action),
                "\(action.rawValue) 的图标不在 MWDATDisplay 图标目录中"
            )
        }
    }

    func testPermissionViewBuildsWithSummary() {
        let view = AgentDisplayPermissionMapping.makeView(
            summary: "Agent 想发送一条消息",
            onAllow: {},
            onDeny: {},
            onLater: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionViewBuildsWithoutSummary() {
        let view = AgentDisplayPermissionMapping.makeView(
            summary: "",
            onAllow: {},
            onDeny: {},
            onLater: {}
        )
        XCTAssertNotNil(view)
    }

    func testApprovalFeedbackMappingForAllow() {
        let feedback = AgentApprovalFeedbackMapping.feedback(for: .allow)
        XCTAssertEqual(feedback.title, "Done")
        XCTAssertFalse(feedback.text.isEmpty, "allow 反馈文案不能为空")
    }

    func testApprovalFeedbackMappingForDeny() {
        let feedback = AgentApprovalFeedbackMapping.feedback(for: .deny)
        XCTAssertEqual(feedback.title, "Denied")
        XCTAssertFalse(feedback.text.isEmpty, "deny 反馈文案不能为空")
    }
}
