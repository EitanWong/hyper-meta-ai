/*
 * Share Extension（跨 App 分享 → Hyper）
 * 任意 App 的文本 / URL 经系统分享面板进入：选择目标（长期记忆 / 清单 / Agent），
 * 写入 App Group 队列后唤起 App 处理；队列 JSON 与 App 侧 AgentShareQueue 镜像一致。
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 队列镜像（与 App 侧 AgentShareRequest / AgentShareDestination 字段一致）

/// 分享目标（rawValue 与 App 侧 AgentShareDestination 一致）
enum ShareDestinationPayload: String, CaseIterable {
    case memory
    case list
    case agent
}

/// 分享请求载荷（App Group JSON；字段与 App 侧解码一致）
struct ShareRequestPayload: Codable {
    var id: UUID
    var text: String
    var destination: String
    var date: Date
}

/// 队列写入（App 与扩展共享的通道；上限 20 条滚动，丢最旧）
enum ShareQueueWriter {
    static let suiteName = "group.com.lunflux.hyper-meta-ai"
    static let key = "agent.share.queue"
    static let maxCount = 20

    static func enqueue(_ payload: ShareRequestPayload) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        var items: [ShareRequestPayload] = []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ShareRequestPayload].self, from: data) {
            items = decoded
        }
        items.append(payload)
        let trimmed = Array(items.suffix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - 草稿提取

/// 从分享上下文提取的内容草稿
struct ShareDraft {
    var text: String
    var url: String?
    var title: String?

    /// 组合文本：正文（或标题）→ URL；空内容返回空串
    var composed: String {
        var lines: [String] = []
        let textValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !textValue.isEmpty {
            lines.append(textValue)
        } else if !titleValue.isEmpty, titleValue != url {
            lines.append(titleValue)
        }
        if let url, !url.isEmpty {
            lines.append(url)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分享控制器

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractDraft { [weak self] draft in
            guard let self else { return }
            let rootView = ShareComposeView(
                draft: draft,
                onCancel: { [weak self] in self?.finish(cancelled: true, payload: nil) },
                onShare: { [weak self] payload in self?.finish(cancelled: false, payload: payload) }
            )
            let hosting = UIHostingController(rootView: rootView)
            hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
        }
    }

    /// 从 NSExtensionItem 附件提取文本与 URL（异步，完成后回主线程）
    private func extractDraft(completion: @escaping (ShareDraft) -> Void) {
        var text = ""
        var url: String?
        var title: String?
        let group = DispatchGroup()
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            if title == nil, let attributedTitle = item.attributedTitle?.string {
                title = attributedTitle
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                        if let value = item as? URL {
                            url = value.absoluteString
                        } else if let value = item as? String, value.hasPrefix("http") {
                            url = value
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                        if let value = item as? String {
                            text = value
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                        if let value = item as? String {
                            text = value
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            completion(ShareDraft(text: text, url: url, title: title))
        }
    }

    private func finish(cancelled: Bool, payload: ShareRequestPayload?) {
        if let payload {
            ShareQueueWriter.enqueue(payload)
        }
        if !cancelled, let url = URL(string: "hypermetaai://share") {
            // 唤起 App 处理；受系统限制未唤起时，App 下次回前台也会自动消费队列
            extensionContext?.open(url) { _ in }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

// MARK: - 组合界面

struct ShareComposeView: View {
    let draft: ShareDraft
    var onCancel: () -> Void
    var onShare: (ShareRequestPayload) -> Void

    @State private var destination: ShareDestinationPayload = .agent

    var body: some View {
        NavigationStack {
            Form {
                Section("share.preview.title".localized) {
                    Text(draft.composed.isEmpty ? "share.preview.empty".localized : draft.composed)
                        .font(.body)
                        .lineLimit(6)
                }
                Section("share.destination.title".localized) {
                    Picker("share.destination.title".localized, selection: $destination) {
                        ForEach(ShareDestinationPayload.allCases, id: \.self) { item in
                            Text(label(for: item)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    Button(action: submit) {
                        Label("share.action.share".localized, systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(draft.composed.isEmpty)
                }
            }
            .navigationTitle("share.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("share.action.cancel".localized, action: onCancel)
                }
            }
        }
    }

    private func label(for destination: ShareDestinationPayload) -> String {
        switch destination {
        case .memory: return "share.destination.memory".localized
        case .list: return "share.destination.list".localized
        case .agent: return "share.destination.agent".localized
        }
    }

    private func submit() {
        onShare(ShareRequestPayload(
            id: UUID(),
            text: draft.composed,
            destination: destination.rawValue,
            date: Date()
        ))
    }
}

private extension String {
    /// 扩展内本地化（扩展为独立 bundle，App 侧 String.localized 不可见）
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
}
