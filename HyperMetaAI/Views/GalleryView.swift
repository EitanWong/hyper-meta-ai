/*
 * Gallery View
 * 图库 - 显示拍摄的照片
 */

import SwiftUI

struct GalleryView: View {
    let streamViewModel: StreamSessionViewModel
    @State private var photos: [GalleryPhoto] = []
    @State private var selectedPhoto: GalleryPhoto?
    @State private var showPhotoDetail = false
    /// 系统入口深链要打开的照片（Spotlight 点按）；加载后只打开一次
    @State private var pendingPhotoID: UUID?
    @ObservedObject private var navigationRouter = AppNavigationRouter.shared

    let columns = [
        GridItem(.flexible(), spacing: AppSpacing.sm),
        GridItem(.flexible(), spacing: AppSpacing.sm),
        GridItem(.flexible(), spacing: AppSpacing.sm)
    ]

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                AppColors.secondaryBackground
                    .ignoresSafeArea()

                if photos.isEmpty {
                    // Empty state
                    VStack(spacing: AppSpacing.lg) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(AppColors.textTertiary)

                        Text("gallery.empty.title".localized)
                            .font(AppTypography.title2)
                            .foregroundColor(AppColors.textPrimary)

                        Text("gallery.empty.subtitle".localized)
                            .font(AppTypography.subheadline)
                            .foregroundColor(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppSpacing.xl)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: AppSpacing.sm) {
                            ForEach(photos) { photo in
                                PhotoGridItem(photo: photo)
                                    .onTapGesture {
                                        selectedPhoto = photo
                                        showPhotoDetail = true
                                    }
                            }
                        }
                        .padding(AppSpacing.md)
                    }
                }
            }
            .navigationTitle("tab.gallery".localized)
            .sheet(isPresented: $showPhotoDetail) {
                if let photo = selectedPhoto {
                    PhotoDetailView(photo: photo, streamViewModel: streamViewModel)
                }
            }
            .onChange(of: navigationRouter.pendingDestination) { _, _ in
                consumeNavigationIfNeeded()
            }
    }
    .onAppear {
      loadPhotos()
      consumeNavigationIfNeeded()
    }
    .onReceive(NotificationCenter.default.publisher(for: .capturedPhotosChanged)) { _ in
      loadPhotos()
    }
  }

  private func loadPhotos() {
    photos = CapturedPhotoStore.records.compactMap { record in
      guard let image = CapturedPhotoStore.loadImage(fileName: record.fileName) else { return nil }
      return GalleryPhoto(
        id: record.id,
        image: image,
        timestamp: record.createdAt,
        aiDescription: record.aiDescription
      )
    }
  }

  /// 消费系统入口的导航请求（Spotlight 照片点按 → 切 Tab 后打开详情）
  private func consumeNavigationIfNeeded() {
    guard case .gallery(let id)? = navigationRouter.consume(where: {
      if case .gallery = $0 { return true }
      return false
    }) else { return }
    pendingPhotoID = id
    loadPhotos()
    openPendingPhotoIfPossible()
  }

  /// 找到待打开照片并弹出详情（照片已删除则静默忽略）
  private func openPendingPhotoIfPossible() {
    guard let id = pendingPhotoID else { return }
    pendingPhotoID = nil
    guard let photo = photos.first(where: { $0.id == id }) else { return }
    selectedPhoto = photo
    showPhotoDetail = true
  }
}

// MARK: - Gallery Photo Model

struct GalleryPhoto: Identifiable {
  let id: UUID
  let image: UIImage
  let timestamp: Date
  let aiDescription: String?

  init(
    id: UUID = UUID(),
    image: UIImage,
    timestamp: Date,
    aiDescription: String? = nil
  ) {
    self.id = id
    self.image = image
    self.timestamp = timestamp
    self.aiDescription = aiDescription
  }
}

// MARK: - Photo Grid Item

struct PhotoGridItem: View {
    let photo: GalleryPhoto

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: photo.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .cornerRadius(AppCornerRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.md)
                        .stroke(AppColors.textTertiary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Photo Detail View

struct PhotoDetailView: View {
  let photo: GalleryPhoto
  let streamViewModel: StreamSessionViewModel
  @ObservedObject private var openClawService = OpenClawNodeService.shared
  @Environment(\.dismiss) private var dismiss
  @State private var showDeleteConfirmation = false
  @State private var isOCRing = false
  @State private var ocrResultText = ""
  @State private var showOCRResult = false
  @State private var ocrCopied = false
  /// 图库聊天入口：照片直达或 OCR 文字直达（二选一，同一 fullScreenCover）
  @State private var chatPayload: GalleryChatPayload?
  /// 发送前选择大脑：待发送载荷（选完大脑后转为 chatPayload）
  @State private var pendingPayload: GalleryChatPayload?
  @State private var showBrainPicker = false

  var body: some View {
    NavigationView {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack(spacing: 0) {
          // Photo
          Image(uiImage: photo.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          // Captured time
          Text(String(format: "gallery.capturedAt".localized, photo.timestamp.formatted()))
            .font(AppTypography.footnote)
            .foregroundColor(.white.opacity(0.7))
            .padding(.vertical, AppSpacing.sm)

          // AI Description (if available)
          if let description = photo.aiDescription {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              Text("gallery.ai".localized)
                .font(AppTypography.headline)
                .foregroundColor(.white)

              Text(description)
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .background(Color.black.opacity(0.8))
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .foregroundColor(.white)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showDeleteConfirmation = true
          } label: {
            Image(systemName: "trash")
              .foregroundColor(.red)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            sharePhoto()
          } label: {
            Image(systemName: "square.and.arrow.up")
              .foregroundColor(.white)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            requestChat(photo: photo)
          } label: {
            Image(systemName: "paperplane.fill")
              .foregroundColor(.white)
          }
          .accessibilityLabel("gallery.sendToAgent".localized)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            runOCR()
          } label: {
            if isOCRing {
              ProgressView()
                .tint(.white)
            } else {
              Image(systemName: "text.viewfinder")
                .foregroundColor(.white)
            }
          }
          .disabled(isOCRing)
          .accessibilityLabel("agent.vision.ocr.button".localized)
        }
      }
      .confirmationDialog(
        Text("gallery.deleteConfirm".localized),
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("gallery.delete".localized, role: .destructive) {
          CapturedPhotoStore.deletePhoto(id: photo.id)
          dismiss()
        }
      }
      .sheet(isPresented: $showOCRResult) {
        OCRResultSheet(
          text: ocrResultText,
          copied: $ocrCopied,
          onClose: { showOCRResult = false },
          onSendToAgent: { text in
            showOCRResult = false
            requestChat(ocrText: text)
          }
        )
      }
      .fullScreenCover(item: $chatPayload) { payload in
        let route = payload.route
        switch payload {
        case .photo(let photo, _):
          AgentChatView(
            kind: route.kind,
            streamViewModel: streamViewModel,
            customConfig: route.customConfig,
            pendingPhoto: photo.image
          )
        case .ocrText(let text, _):
          AgentChatView(
            kind: route.kind,
            streamViewModel: streamViewModel,
            customConfig: route.customConfig,
            pendingUserText: text
          )
        }
      }
      .confirmationDialog(
        Text("gallery.brain.title".localized),
        isPresented: $showBrainPicker,
        titleVisibility: .visible
      ) {
        Button("gallery.brain.auto".localized) {
          openChat(route: autoRoute)
        }
        Button("Hermes") {
          openChat(route: .hermes)
        }
        if openClawService.connectionState == .connected {
          Button("OpenClaw") {
            openChat(route: .openclaw)
          }
        }
        if let config = CustomAgentStore.configs.first {
          Button(config.name) {
            openChat(route: .custom(config))
          }
        }
        Button("gallery.brain.cancel".localized, role: .cancel) {
          pendingPayload = nil
        }
      }
    }
  }

  /// 发送前先选大脑：暂存载荷并弹出选择
  private func requestChat(photo: GalleryPhoto) {
    pendingPayload = .photo(photo, autoRoute)
    showBrainPicker = true
  }

  private func requestChat(ocrText: String) {
    pendingPayload = .ocrText(ocrText, autoRoute)
    showBrainPicker = true
  }

  /// 按所选大脑打开直达聊天
  private func openChat(route: GalleryAgentRoute) {
    defer { pendingPayload = nil }
    guard let payload = pendingPayload else { return }
    switch payload {
    case .photo(let photo, _):
      chatPayload = .photo(photo, route)
    case .ocrText(let text, _):
      chatPayload = .ocrText(text, route)
    }
  }

  /// 「自动」选项：沿用场景 AI 辅助的优先级分发
  private var autoRoute: GalleryAgentRoute {
    GalleryAgentRoute.resolve(
      hermesAvailable: HermesService.shared.isEnabled,
      openClawAvailable: openClawService.connectionState == .connected,
      customConfig: CustomAgentStore.configs.first
    )
  }

  private func runOCR() {
    guard !isOCRing else { return }
    isOCRing = true
    Task {
      let text = await VisionOCRService.recognizedText(in: photo.image)
      ocrResultText = text
      ocrCopied = false
      isOCRing = false
      showOCRResult = true
    }
  }

  private func sharePhoto() {
    let activityVC = UIActivityViewController(
      activityItems: [photo.image],
      applicationActivities: nil
    )

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootViewController = windowScene.windows.first?.rootViewController {
      rootViewController.present(activityVC, animated: true)
    }
  }
}

// MARK: - Gallery Chat Payload

/// 图库 → 聊天页直达载荷：照片（视野上下文发送）或 OCR 文字（用户消息发送）
private enum GalleryChatPayload: Identifiable {
  case photo(GalleryPhoto, GalleryAgentRoute)
  case ocrText(String, GalleryAgentRoute)

  /// 用户选择（或自动分发）的大脑路由
  var route: GalleryAgentRoute {
    switch self {
    case .photo(_, let route), .ocrText(_, let route):
      return route
    }
  }

  var id: String {
    switch self {
    case .photo(let photo, _): return "photo-\(photo.id.uuidString)"
    case .ocrText(let text, _): return "ocr-\(text)"
    }
  }
}

/// 图库直达聊天的大脑分发（纯逻辑，可测）：
/// 与场景 AI 辅助同一优先级（Hermes → OpenClaw → 自定义 Agent）；
/// 全部不可用时回退 Hermes 入口（聊天页自带配置引导，不静默失败）。
enum GalleryAgentRoute: Equatable {
  case hermes
  case openclaw
  case custom(CustomAgentConfig?)

  var kind: AgentKind {
    switch self {
    case .hermes, .custom: return .hermes
    case .openclaw: return .openclaw
    }
  }

  var customConfig: CustomAgentConfig? {
    switch self {
    case .custom(let config): return config
    default: return nil
    }
  }

  static func resolve(
    hermesAvailable: Bool,
    openClawAvailable: Bool,
    customConfig: CustomAgentConfig?
  ) -> GalleryAgentRoute {
    if hermesAvailable { return .hermes }
    if openClawAvailable { return .openclaw }
    if let customConfig { return .custom(customConfig) }
    return .hermes
  }
}

// MARK: - OCR Result Sheet

/// 图库照片端侧取词结果（离线 Apple Vision；iOS 18+ 支持端侧翻译）
private struct OCRResultSheet: View {
  let text: String
  @Binding var copied: Bool
  let onClose: () -> Void
  let onSendToAgent: (String) -> Void

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 12) {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if text.isEmpty {
              Text("agent.vision.ocr.empty".localized)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text(text)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
              if #available(iOS 18.0, *) {
                OnDeviceTranslationView(text: text)
              } else {
                Text("agent.vision.ocr.translate.unsupported".localized)
                  .font(.system(size: 12))
                  .foregroundColor(.secondary)
              }
            }
          }
          .padding()
        }
        HStack(spacing: 12) {
          Button {
            UIPasteboard.general.string = text
            copied = true
          } label: {
            Label(
              copied ? "agent.vision.ocr.copied".localized : "agent.vision.ocr.copy".localized,
              systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
          }
          .disabled(text.isEmpty)

          ShareLink(item: text) {
            Label("settings.diagnostics.share".localized, systemImage: "square.and.arrow.up")
              .font(.system(size: 14, weight: .semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .background(Color.gray.opacity(0.2))
              .cornerRadius(10)
          }
          .disabled(text.isEmpty)

          Button {
            onSendToAgent(text)
          } label: {
            Label("gallery.sendToAgent".localized, systemImage: "paperplane")
              .font(.system(size: 14, weight: .semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .background(Color.accentColor.opacity(0.25))
              .cornerRadius(10)
          }
          .disabled(text.isEmpty)
        }
        .padding(.horizontal)
      }
      .navigationTitle("agent.vision.ocr.title".localized)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            TTSService.shared.stop()
            TTSService.shared.speak(text)
          } label: {
            Image(systemName: "speaker.wave.2")
          }
          .disabled(text.isEmpty)
          .accessibilityLabel("agent.vision.ocr.speak".localized)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            onClose()
          } label: {
            Text("agent.vision.ocr.close".localized)
          }
        }
      }
    }
  }
}

@MainActor
private struct GalleryPreviewHost: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    GalleryView(streamViewModel: dependencies.streamViewModel)
  }
}

@MainActor
private struct PhotoDetailPreviewHost: View {
  @StateObject private var dependencies = PreviewDependencies()

  var body: some View {
    PhotoDetailView(
      photo: GalleryPhoto(
        image: UIImage(systemName: "mountain.2.fill")!,
        timestamp: .now,
        aiDescription: "A preview image captured from the glasses."
      ),
      streamViewModel: dependencies.streamViewModel
    )
  }
}

#Preview("Empty Gallery") {
  GalleryPreviewHost()
}

#Preview("Photo Detail") {
  PhotoDetailPreviewHost()
}
