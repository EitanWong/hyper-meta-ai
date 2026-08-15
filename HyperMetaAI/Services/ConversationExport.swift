/*
 * Conversation Export
 * 对话记录导出文本（纯逻辑，可测）：头部元数据 + 逐条消息，
 * 供会话详情页一键分享为纯文本。
 */

import Foundation

/// 对话导出文本构造（纯逻辑，可测）
enum ConversationExportBuilder {
  /// 角色标签（导出文本固定用语，跨语言一致便于测试）
  static let userLabel = "用户"
  static let assistantLabel = "助手"

  /// 构造导出文本：头部（时间 / 模型 / 语言 / 条数）+ 逐条消息
  static func exportText(
    conversation: ConversationRecord,
    dateFormatter: DateFormatter = ConversationExportBuilder.makeFormatter()
  ) -> String {
    var lines: [String] = []
    lines.append("Hyper Meta AI 对话记录")
    lines.append("时间：\(dateFormatter.string(from: conversation.timestamp))")
    lines.append("模型：\(conversation.aiModel)")
    lines.append("语言：\(conversation.language)")
    lines.append("消息：\(conversation.messages.count) 条")
    lines.append("")
    for message in conversation.messages {
      let role = message.role == .user ? userLabel : assistantLabel
      lines.append("[\(role)] \(dateFormatter.string(from: message.timestamp))")
      lines.append(message.content)
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  static func makeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }
}
