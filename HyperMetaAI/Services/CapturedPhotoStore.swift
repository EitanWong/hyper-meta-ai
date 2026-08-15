/*
 * Captured Photo Store
 * 眼镜拍摄照片的本地存档：拍摄成功即把 JPEG 写入 Documents/CapturedPhotos，
 * 元数据（文件名 / 时间 / 可选 AI 描述）存 UserDefaults（上限 50 张滚动裁剪），
 * 图库页从此加载。文件命名与唯一化保持纯函数便于测试。
 */

import Foundation
import UIKit

extension Notification.Name {
  /// 拍摄照片存档变化（新增 / 删除），图库页监听后刷新
  static let capturedPhotosChanged = Notification.Name("captured.photos.changed")
}

/// 一张已存档的拍摄照片
struct CapturedPhotoRecord: Codable, Equatable, Identifiable {
  var id: UUID
  /// 文件名（Documents/CapturedPhotos/ 下）
  var fileName: String
  var createdAt: Date
  /// 可选 AI 描述（识图结果回填）
  var aiDescription: String?

  init(
    id: UUID = UUID(),
    fileName: String,
    createdAt: Date = Date(),
    aiDescription: String? = nil
  ) {
    self.id = id
    self.fileName = fileName
    self.createdAt = createdAt
    self.aiDescription = aiDescription
  }
}

/// 照片文件命名（纯逻辑，可测）
enum CapturedPhotoNaming {
  static let filePrefix = "IMG-"

  /// 文件名：IMG-YYYYMMDD-HHmmss.jpg（formatter 可注入以便测试）
  static func fileName(
    for date: Date,
    formatter: DateFormatter = CapturedPhotoNaming.makeFormatter()
  ) -> String {
    filePrefix + formatter.string(from: date) + ".jpg"
  }

  static func makeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }

  /// 文件名唯一化：同名时追加 -2、-3…（同一秒多次拍摄不覆盖）
  static func uniqueFileName(base: String, existing: Set<String>) -> String {
    guard existing.contains(base) else { return base }
    let name = (base as NSString).deletingPathExtension
    let ext = (base as NSString).pathExtension
    var index = 2
    while true {
      let candidate = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
      if !existing.contains(candidate) { return candidate }
      index += 1
    }
  }
}

/// 照片文件落盘（目录可注入以便测试）
enum CapturedPhotoFileStore {
  static let directoryName = "CapturedPhotos"

  static func directory() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  static func fileURL(
    fileName: String,
    directory: URL = CapturedPhotoFileStore.directory()
  ) -> URL {
    directory.appendingPathComponent(fileName)
  }

  /// 写入照片数据；目录不存在时自动创建；失败返回 false
  @discardableResult
  static func save(
    data: Data,
    fileName: String,
    directory: URL = CapturedPhotoFileStore.directory()
  ) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL(fileName: fileName, directory: directory), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  static func delete(
    fileName: String,
    directory: URL = CapturedPhotoFileStore.directory()
  ) {
    try? FileManager.default.removeItem(at: fileURL(fileName: fileName, directory: directory))
  }
}

/// 拍摄照片元数据存储（UserDefaults JSON 持久化，上限 50 张）
enum CapturedPhotoStore {
  static let key = "captured.photos"
  static let maxCount = 50

  static var records: [CapturedPhotoRecord] {
    get {
      guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
      let decoded = (try? JSONDecoder().decode([CapturedPhotoRecord].self, from: data)) ?? []
      return decoded.sorted { $0.createdAt > $1.createdAt }
    }
    set {
      let trimmed = Array(newValue.prefix(maxCount))
      guard let data = try? JSONEncoder().encode(trimmed) else { return }
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  /// 新增一张照片：数据落盘 + 元数据入列；同名文件自动唯一化。
  /// 返回 nil 表示落盘失败（无记录写入）。
  @discardableResult
  static func addPhoto(
    data: Data,
    createdAt: Date = Date(),
    aiDescription: String? = nil,
    directory: URL = CapturedPhotoFileStore.directory()
  ) -> CapturedPhotoRecord? {
    let base = CapturedPhotoNaming.fileName(for: createdAt)
    let existing = Set(records.map(\.fileName))
    let fileName = CapturedPhotoNaming.uniqueFileName(base: base, existing: existing)
    guard CapturedPhotoFileStore.save(data: data, fileName: fileName, directory: directory) else {
      return nil
    }
    let record = CapturedPhotoRecord(
      fileName: fileName,
      createdAt: createdAt,
      aiDescription: aiDescription
    )
    var items = records
    items.insert(record, at: 0)
    records = items
    pruneOrphanFiles(directory: directory)
    NotificationCenter.default.post(name: .capturedPhotosChanged, object: nil)
    return record
  }

  /// 删除一张照片（元数据 + 文件）
  static func deletePhoto(
    id: UUID,
    directory: URL = CapturedPhotoFileStore.directory()
  ) {
    guard let record = records.first(where: { $0.id == id }) else { return }
    CapturedPhotoFileStore.delete(fileName: record.fileName, directory: directory)
    records = records.filter { $0.id != id }
    NotificationCenter.default.post(name: .capturedPhotosChanged, object: nil)
  }

  /// 回填照片的 AI 描述（端侧识别结果）；空内容视为清除；未知 id 无操作
  static func updateDescription(
    id: UUID,
    description: String?
  ) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var items = records
    items[index].aiDescription = trimmed.isEmpty ? nil : trimmed
    records = items
  }

  /// 读取照片图（文件缺失返回 nil）
  static func loadImage(
    fileName: String,
    directory: URL = CapturedPhotoFileStore.directory()
  ) -> UIImage? {
    UIImage(contentsOfFile: CapturedPhotoFileStore.fileURL(fileName: fileName, directory: directory).path)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }

  /// 清理目录里不在元数据中的孤儿文件（上限裁剪后磁盘不残留）
  static func pruneOrphanFiles(directory: URL) {
    let kept = Set(records.map(\.fileName))
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) else { return }
    for file in files where !kept.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
