import XCTest
@testable import HyperMetaAI

/// 本地化键存在性守卫：本轮「UI 本地化一致性」新增的键必须能在当前 bundle 解析
/// （中英 strings 文件键集一致性由交付检查 diff 保证，这里防键漂移/误删）。
final class LocalizationKeyPresenceTests: XCTestCase {

    private let keys = [
        "records.tab.liveai", "records.tab.leaneat", "records.tab.wordlearn",
        "omni.realtime.title", "settings.outputLanguage.footer",
        "settings.apikey.google.title", "settings.apikey.gemini.title",
        "agent.form.host", "agent.form.port", "agent.form.session",
        "agent.form.status", "agent.form.gateway", "agent.form.model",
        "agent.form.conversation", "stream.endingIn",
        "nonstream.title", "nonstream.hint", "nonstream.waiting", "nonstream.gettingStarted",
        "rtmp.settings.localbrain.toggle", "rtmp.settings.localbrain.footer",
        "rtmp.scene.title.polish.done.local",
        "rtmp.scene.assistant.local", "rtmp.scene.assistant.local.hint",
        "rtmp.scene.assistant.local.error", "rtmp.scene.assistant.local.timeout",
        "rtmp.scene.assistant.local.busy",
    ]

    func testNewKeysResolveInCurrentBundle() {
        for key in keys {
            let value = LanguageManager.currentBundle.localizedString(
                forKey: key,
                value: nil,
                table: nil
            )
            XCTAssertNotEqual(value, key, "本地化键缺失: \(key)")
            XCTAssertFalse(value.isEmpty, "本地化键为空: \(key)")
        }
    }

    func testValuesDifferBetweenLanguages() {
        for key in keys {
            let en = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "")?
                .localizedString(forKey: key, value: nil, table: nil)
            let zh = Bundle(path: Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") ?? "")?
                .localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotNil(en, "缺少 en.lproj: \(key)")
            XCTAssertNotNil(zh, "缺少 zh-Hans.lproj: \(key)")
            XCTAssertNotEqual(en, key, "en 缺失键: \(key)")
            XCTAssertNotEqual(zh, key, "zh-Hans 缺失键: \(key)")
        }
    }
}
