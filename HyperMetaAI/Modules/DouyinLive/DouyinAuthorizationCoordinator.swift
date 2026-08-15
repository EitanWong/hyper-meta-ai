import Foundation
import UIKit
import os.log

private let douyinAuthorizationLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "DouyinAuthorization"
)

enum DouyinAuthorizationPhase: Equatable {
    case idle
    case preparing
    case opening
    case awaitingConfirmation
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .opening:
            return true
        case .idle, .awaitingConfirmation, .failed:
            return false
        }
    }
}

enum DouyinAuthorizationError: LocalizedError {
    case qrCodeTimedOut
    case invalidQRCode
    case loginPage(String)
    case appUnavailable
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .qrCodeTimedOut:
            return "douyin.error.authorization.timeout".localized
        case .invalidQRCode:
            return "douyin.error.authorization.invalid".localized
        case .loginPage(let detail):
            return String(format: "douyin.error.authorization.page".localized, detail)
        case .appUnavailable:
            return "douyin.error.authorization.app".localized
        case .sessionNotReady:
            return "douyin.error.authorization.session".localized
        }
    }
}

@MainActor
protocol DouyinAuthorizationPreparing: AnyObject {
    func prepareFreshAuthorization() async throws -> URL
}

protocol DouyinAuthorizationRouting: Sendable {
    func route(for qrCodeURL: URL) throws -> URL
}

@MainActor
protocol DouyinExternalURLOpening: AnyObject {
    func open(_ url: URL) async -> Bool
}

struct DouyinAuthorizationRouteBuilder: DouyinAuthorizationRouting {
    static func canRoute(_ qrCodeURL: URL) -> Bool {
        qrCodeURL.scheme?.lowercased() == "https"
            && qrCodeURL.host?.lowercased() == "aweme.snssdk.com"
            && qrCodeURL.path.hasPrefix("/ucenter_web/app/aweme/scan_login/")
    }

    func route(for qrCodeURL: URL) throws -> URL {
        guard Self.canRoute(qrCodeURL) else {
            throw DouyinAuthorizationError.invalidQRCode
        }

        var components = URLComponents()
        components.scheme = "snssdk1128"
        components.host = "webview"
        components.queryItems = [
            URLQueryItem(name: "url", value: qrCodeURL.absoluteString),
            URLQueryItem(name: "hide_nav_bar", value: "1"),
        ]

        guard let route = components.url,
              route.path.isEmpty else {
            throw DouyinAuthorizationError.invalidQRCode
        }
        return route
    }
}

@MainActor
final class DouyinApplicationURLOpener: DouyinExternalURLOpening {
    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}

@MainActor
final class DouyinAuthorizationCoordinator: ObservableObject {
    @Published private(set) var phase: DouyinAuthorizationPhase = .idle

    private let preparer: any DouyinAuthorizationPreparing
    private let router: any DouyinAuthorizationRouting
    private let opener: any DouyinExternalURLOpening

    init(
        preparer: any DouyinAuthorizationPreparing,
        router: any DouyinAuthorizationRouting = DouyinAuthorizationRouteBuilder(),
        opener: (any DouyinExternalURLOpening)? = nil
    ) {
        self.preparer = preparer
        self.router = router
        self.opener = opener ?? DouyinApplicationURLOpener()
    }

    func start() async {
        switch phase {
        case .idle, .failed:
            break
        case .preparing, .opening, .awaitingConfirmation:
            return
        }

        phase = .preparing
        douyinAuthorizationLogger.info("Preparing fresh Douyin app authorization")
        do {
            let qrCodeURL = try await preparer.prepareFreshAuthorization()
            try Task.checkCancellation()
            let route = try router.route(for: qrCodeURL)

            phase = .opening
            douyinAuthorizationLogger.info("Opening Douyin app authorization route")
            guard await opener.open(route) else {
                throw DouyinAuthorizationError.appUnavailable
            }
            try Task.checkCancellation()
            phase = .awaitingConfirmation
            douyinAuthorizationLogger.info("Douyin app authorization opened")
            debugTrace("Direct snssdk1128 authorization opened")
        } catch is CancellationError {
            phase = .idle
            douyinAuthorizationLogger.info("Douyin app authorization cancelled")
        } catch {
            phase = .failed(error.localizedDescription)
            douyinAuthorizationLogger.error(
                "Douyin app authorization failed error=\(error.localizedDescription, privacy: .public)"
            )
            debugTrace("Direct authorization failed: \(error.localizedDescription)")
        }
    }

    func sessionDidRestore() {
        phase = .idle
    }

    func sessionVerificationDidFail() {
        guard phase == .awaitingConfirmation || phase == .idle else { return }
        phase = .failed(DouyinAuthorizationError.sessionNotReady.localizedDescription)
    }

    private func debugTrace(_ message: String) {
        #if DEBUG
        print("[DouyinLiveDebug] \(message)")
        #endif
    }
}
