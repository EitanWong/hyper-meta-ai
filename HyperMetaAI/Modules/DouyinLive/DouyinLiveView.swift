import SwiftUI

struct DouyinLiveView: View {
    @ObservedObject private var streamViewModel: StreamSessionViewModel
    @StateObject private var coordinator: DouyinLiveCoordinator
    @StateObject private var runtime: DouyinWebRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var showsLogin = false
    @State private var sessionRestoreTask: Task<Void, Never>?
    @State private var isClosing = false
    @State private var isLoggingOut = false

    init(
        streamViewModel: StreamSessionViewModel,
        coordinator: DouyinLiveCoordinator,
        runtime: DouyinWebRuntime
    ) {
        self.streamViewModel = streamViewModel
        _coordinator = StateObject(wrappedValue: coordinator)
        _runtime = StateObject(wrappedValue: runtime)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview

            VStack(spacing: 0) {
                header
                Spacer(minLength: AppSpacing.md)

                if coordinator.phase.isLive {
                    liveDashboard
                }

                controls
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showsLogin) {
            DouyinLoginSheet(runtime: runtime, coordinator: coordinator)
        }
        .alert("error".localized, isPresented: errorBinding) {
            Button("ok".localized) {
                coordinator.dismissError()
            }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .onAppear {
            coordinator.prepareLogin()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DebugOpenDouyinLive") {
                showsLogin = true
            }
            #endif
        }
        .onChange(of: runtime.isPageReady) { _, isReady in
            if isReady { restoreSessionIfPossible() }
        }
        .onChange(of: runtime.currentURL) { _, _ in
            restoreSessionIfPossible()
        }
        .onDisappear {
            guard !AppIdentity.isRunningPreview else { return }
            sessionRestoreTask?.cancel()
            sessionRestoreTask = nil
            Task {
                await coordinator.shutdown()
            }
        }
    }

    private var preview: some View {
        Group {
            if let frame = streamViewModel.currentVideoFrame,
               streamViewModel.cameraCaptureState.isStreaming {
                GeometryReader { geometry in
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            } else {
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("douyin.preview.waiting".localized)
                        .font(AppTypography.callout)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .ignoresSafeArea()
        .overlay {
            LinearGradient(
                colors: [.black.opacity(0.66), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("common.close".localized)

            VStack(alignment: .leading, spacing: 2) {
                Text("douyin.title".localized)
                    .font(AppTypography.headline)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(AppTypography.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Spacer()

            if let account = coordinator.account {
                Menu {
                    Button(role: .destructive) {
                        logout()
                    } label: {
                        Label(
                            "douyin.logout".localized,
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                    }
                    .disabled(isLoggingOut)
                } label: {
                    HStack(spacing: 6) {
                        if isLoggingOut {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                        Text(account.nickname)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 92)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(AppTypography.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(height: 34)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
                }
                .accessibilityLabel(account.nickname)
                .accessibilityHint("douyin.account.menu.hint".localized)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.sm)
    }

    private var liveDashboard: some View {
        VStack(spacing: AppSpacing.sm) {
            metricsStrip

            if let warning = coordinator.runtimeWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.yellow)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.sm)
            }

            eventFeed
        }
        .padding(.horizontal, AppSpacing.md)
    }

    private var metricsStrip: some View {
        HStack(spacing: 0) {
            metricCell(
                icon: "person.2.fill",
                label: "douyin.metric.online".localized,
                value: compact(coordinator.metrics.viewerCount),
                color: .cyan
            )
            metricCell(
                icon: "heart.fill",
                label: "douyin.metric.likes".localized,
                value: compact(coordinator.metrics.likeCount),
                color: .pink
            )
            metricCell(
                icon: "gift.fill",
                label: "douyin.metric.gifts".localized,
                value: compact(coordinator.metrics.giftCount),
                color: .yellow
            )
            metricCell(
                icon: "speedometer",
                label: "FPS",
                value: String(format: "%.1f", coordinator.publishStats.framesPerSecond),
                color: .green
            )
        }
        .frame(height: 66)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
    }

    private func metricCell(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var eventFeed: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                if coordinator.events.isEmpty {
                    Text("douyin.events.empty".localized)
                        .font(AppTypography.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(coordinator.events.prefix(6)) { event in
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: eventIcon(event.kind))
                                .foregroundStyle(eventColor(event.kind))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(event.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.76))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(AppSpacing.sm)
        }
        .frame(height: 154)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
    }

    private var controls: some View {
        VStack(spacing: AppSpacing.md) {
            if streamViewModel.requiresDATGlassesAppUpdate {
                Button {
                    streamViewModel.openDATGlassesAppUpdate()
                } label: {
                    Label(
                        DATGlassesAppUpdateGuidance.openUpdateActionTitle,
                        systemImage: "eyeglasses"
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(DouyinPrimaryButtonStyle(color: Color(hex: "19C5C7")))
            }

            switch coordinator.phase {
            case .signedOut, .checkingSession:
                Button {
                    coordinator.prepareLogin()
                    showsLogin = true
                } label: {
                    Label("douyin.login".localized, systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(DouyinPrimaryButtonStyle(color: Color(hex: "19C5C7")))
                .disabled(coordinator.phase.isBusy)

            case .ready:
                TextField("douyin.title.placeholder".localized, text: $coordinator.title)
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.md)
                    .frame(height: 46)
                    .background(.black.opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))

                Button {
                    Task { await coordinator.startLive() }
                } label: {
                    Label("douyin.start".localized, systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(DouyinPrimaryButtonStyle(color: Color(hex: "FE2C55")))

            case .starting, .stopping:
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .tint(.white)
                    Text(coordinator.phase == .starting
                         ? "douyin.starting".localized
                         : "douyin.stopping".localized)
                }
                .font(AppTypography.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.black.opacity(0.64))
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))

            case .live:
                Button {
                    Task { await coordinator.stopLive() }
                } label: {
                    Label("douyin.stop".localized, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(DouyinPrimaryButtonStyle(color: Color(hex: "FE2C55")))

            case .failed:
                Button {
                    coordinator.dismissError()
                } label: {
                    Label("douyin.retry".localized, systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(DouyinPrimaryButtonStyle(color: .orange))
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.lg)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.dismissError() } }
        )
    }

    private var statusText: String {
        switch coordinator.phase {
        case .signedOut: return "douyin.status.signedout".localized
        case .checkingSession: return "douyin.status.checking".localized
        case .ready: return "douyin.status.ready".localized
        case .starting: return "douyin.status.starting".localized
        case .live: return "douyin.status.live".localized
        case .stopping: return "douyin.status.stopping".localized
        case .failed: return "douyin.status.failed".localized
        }
    }

    private var statusColor: Color {
        switch coordinator.phase {
        case .live: return .red
        case .ready: return .green
        case .checkingSession, .starting, .stopping: return .yellow
        case .signedOut: return .gray
        case .failed: return .orange
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        Task {
            await coordinator.shutdown()
            if coordinator.hasActiveRoom {
                isClosing = false
            } else {
                dismiss()
            }
        }
    }

    private func logout() {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        showsLogin = false
        sessionRestoreTask?.cancel()
        sessionRestoreTask = nil

        Task {
            await coordinator.logout()
            isLoggingOut = false
        }
    }

    private func restoreSessionIfPossible() {
        guard runtime.isPageReady,
              runtime.isAuthenticatedPage,
              coordinator.account == nil,
              sessionRestoreTask == nil else {
            return
        }

        sessionRestoreTask = Task {
            _ = await coordinator.restoreSession(reportFailure: false)
            sessionRestoreTask = nil
        }
    }

    private func compact(_ value: Int64) -> String {
        let magnitude = Double(value)
        if magnitude >= 10_000 {
            return String(format: "%.1fw", magnitude / 10_000)
        }
        if magnitude >= 1_000 {
            return String(format: "%.1fk", magnitude / 1_000)
        }
        return String(value)
    }

    private func eventIcon(_ kind: DouyinLiveEvent.Kind) -> String {
        switch kind {
        case .chat: return "bubble.left.fill"
        case .gift: return "gift.fill"
        case .like: return "heart.fill"
        case .member: return "person.crop.circle.badge.plus"
        case .roomStats: return "chart.line.uptrend.xyaxis"
        case .other: return "bell.fill"
        }
    }

    private func eventColor(_ kind: DouyinLiveEvent.Kind) -> Color {
        switch kind {
        case .chat: return .cyan
        case .gift: return .yellow
        case .like: return .pink
        case .member: return .green
        case .roomStats: return .orange
        case .other: return .white.opacity(0.7)
        }
    }
}

private struct DouyinLoginSheet: View {
    @ObservedObject var runtime: DouyinWebRuntime
    @ObservedObject var coordinator: DouyinLiveCoordinator
    @StateObject private var authorization: DouyinAuthorizationCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChecking = false
    @State private var verificationTask: Task<Void, Never>?

    init(runtime: DouyinWebRuntime, coordinator: DouyinLiveCoordinator) {
        self.runtime = runtime
        self.coordinator = coordinator
        _authorization = StateObject(
            wrappedValue: DouyinAuthorizationCoordinator(preparer: runtime)
        )
    }

    var body: some View {
        NavigationStack {
            DouyinLoginWebView(runtime: runtime)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("douyin.login.title".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("common.close".localized)
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if authorization.phase.isBusy || isChecking {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                    Text(
                        isChecking
                            ? "douyin.login.verifying".localized
                            : "douyin.login.preparing".localized
                    )
                        .font(AppTypography.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(.ultraThinMaterial)
            } else if case .failed(let message) = authorization.phase {
                VStack(spacing: AppSpacing.sm) {
                    Text(message)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Task { await authorization.start() }
                    } label: {
                        Label("douyin.retry".localized, systemImage: "arrow.clockwise")
                            .font(AppTypography.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.md)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.primary)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(.ultraThinMaterial)
            }
        }
        .task {
            if runtime.isAuthenticatedPage {
                verifySession()
            } else {
                await authorization.start()
            }
        }
        .onChange(of: runtime.currentURL) { _, url in
            guard let url,
                  url.host == "anchor.douyin.com",
                  !url.path.hasPrefix("/login") else { return }
            verifySession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            verifySession()
        }
        .onDisappear {
            verificationTask?.cancel()
            verificationTask = nil
        }
    }

    private func verifySession() {
        guard !isChecking else { return }
        isChecking = true
        verificationTask = Task {
            defer {
                isChecking = false
                verificationTask = nil
            }

            guard await runtime.waitForAuthenticationCookies() else {
                guard !Task.isCancelled else { return }
                authorization.sessionVerificationDidFail()
                return
            }

            var restored = false
            for _ in 0..<10 {
                guard !Task.isCancelled else { return }
                if runtime.isPageReady {
                    restored = await coordinator.restoreSession(reportFailure: false)
                    if restored { break }
                }
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
            }

            if restored {
                authorization.sessionDidRestore()
                dismiss()
            } else {
                authorization.sessionVerificationDidFail()
            }
        }
    }
}

private struct DouyinPrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.headline)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.sm))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
