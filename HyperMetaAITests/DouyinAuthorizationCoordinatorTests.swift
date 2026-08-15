import Foundation
import XCTest

@testable import HyperMetaAI

@MainActor
final class DouyinAuthorizationCoordinatorTests: XCTestCase {
    func testRouteUsesDirectDouyinSchemeWithoutAnExtraPathComponent() throws {
        let qrCodeURL = URL(
            string: "https://aweme.snssdk.com/ucenter_web/app/aweme/scan_login/index/douyin_scan_code_login/cn/app/index.html?token=TOKEN&state=STATE"
        )!

        let route = try DouyinAuthorizationRouteBuilder().route(for: qrCodeURL)
        let queryItems = URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        XCTAssertEqual(route.scheme, "snssdk1128")
        XCTAssertEqual(route.host, "webview")
        XCTAssertEqual(route.path, "")
        XCTAssertTrue(route.absoluteString.hasPrefix("snssdk1128://webview?"))
        XCTAssertEqual(query["url"]!, qrCodeURL.absoluteString)
        XCTAssertEqual(query["hide_nav_bar"]!, "1")
    }

    func testRouteRejectsUnexpectedQRCodeOriginsAndPaths() {
        let builder = DouyinAuthorizationRouteBuilder()

        XCTAssertThrowsError(
            try builder.route(
                for: URL(string: "https://example.com/ucenter_web/app/aweme/scan_login/index")!
            )
        )
        XCTAssertThrowsError(
            try builder.route(for: URL(string: "https://aweme.snssdk.com/unrelated")!)
        )
    }

    func testStartPreparesFreshQRCodeAndOpensDouyinOnce() async {
        let qrCodeURL = makeQRCodeURL(token: "FIRST")
        let preparer = AuthorizationPreparer(urls: [qrCodeURL])
        let opener = ExternalURLOpener(results: [true])
        let coordinator = DouyinAuthorizationCoordinator(
            preparer: preparer,
            opener: opener
        )

        await coordinator.start()

        XCTAssertEqual(preparer.callCount, 1)
        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertEqual(opener.openedURLs[0].scheme, "snssdk1128")
        XCTAssertEqual(coordinator.phase, .awaitingConfirmation)
    }

    func testRetryAlwaysRequestsAnotherQRCodeBeforeOpeningAgain() async {
        let preparer = AuthorizationPreparer(
            urls: [makeQRCodeURL(token: "EXPIRED"), makeQRCodeURL(token: "FRESH")]
        )
        let opener = ExternalURLOpener(results: [false, true])
        let coordinator = DouyinAuthorizationCoordinator(
            preparer: preparer,
            opener: opener
        )

        await coordinator.start()
        guard case .failed = coordinator.phase else {
            return XCTFail("A failed app launch should expose the retry state")
        }

        await coordinator.start()

        XCTAssertEqual(preparer.callCount, 2)
        XCTAssertEqual(opener.openedURLs.count, 2)
        XCTAssertNotEqual(opener.openedURLs[0], opener.openedURLs[1])
        XCTAssertEqual(coordinator.phase, .awaitingConfirmation)
    }

    func testConcurrentStartsCollapseIntoOneAuthorizationAttempt() async {
        let qrCodeURL = makeQRCodeURL(token: "ONLY")
        let preparer = SuspendedAuthorizationPreparer()
        let opener = ExternalURLOpener(results: [true])
        let coordinator = DouyinAuthorizationCoordinator(
            preparer: preparer,
            opener: opener
        )

        let first = Task { await coordinator.start() }
        await Task.yield()
        let second = Task { await coordinator.start() }
        await second.value

        XCTAssertEqual(preparer.callCount, 1)
        XCTAssertEqual(coordinator.phase, .preparing)

        preparer.resume(with: qrCodeURL)
        await first.value

        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertEqual(coordinator.phase, .awaitingConfirmation)
    }

    func testCancellationReturnsTheAuthorizationStateToIdle() async {
        let preparer = SlowAuthorizationPreparer()
        let opener = ExternalURLOpener(results: [true])
        let coordinator = DouyinAuthorizationCoordinator(
            preparer: preparer,
            opener: opener
        )

        let task = Task { await coordinator.start() }
        await Task.yield()
        task.cancel()
        await task.value

        XCTAssertEqual(preparer.callCount, 1)
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testUnconfirmedSessionMovesToRetryWithANewQRCode() async {
        let preparer = AuthorizationPreparer(
            urls: [makeQRCodeURL(token: "FIRST"), makeQRCodeURL(token: "SECOND")]
        )
        let opener = ExternalURLOpener(results: [true, true])
        let coordinator = DouyinAuthorizationCoordinator(
            preparer: preparer,
            opener: opener
        )

        await coordinator.start()
        coordinator.sessionVerificationDidFail()
        guard case .failed = coordinator.phase else {
            return XCTFail("An unconfirmed session should expose retry")
        }

        await coordinator.start()

        XCTAssertEqual(preparer.callCount, 2)
        XCTAssertEqual(coordinator.phase, .awaitingConfirmation)
    }

    private func makeQRCodeURL(token: String) -> URL {
        URL(
            string: "https://aweme.snssdk.com/ucenter_web/app/aweme/scan_login/index/douyin_scan_code_login/cn/app/index.html?token=\(token)"
        )!
    }
}

@MainActor
private final class AuthorizationPreparer: DouyinAuthorizationPreparing {
    private var urls: [URL]
    private(set) var callCount = 0

    init(urls: [URL]) {
        self.urls = urls
    }

    func prepareFreshAuthorization() async throws -> URL {
        callCount += 1
        guard !urls.isEmpty else {
            throw DouyinAuthorizationError.qrCodeTimedOut
        }
        return urls.removeFirst()
    }
}

@MainActor
private final class SuspendedAuthorizationPreparer: DouyinAuthorizationPreparing {
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var callCount = 0

    func prepareFreshAuthorization() async throws -> URL {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with url: URL) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}

@MainActor
private final class SlowAuthorizationPreparer: DouyinAuthorizationPreparing {
    private(set) var callCount = 0

    func prepareFreshAuthorization() async throws -> URL {
        callCount += 1
        try await Task.sleep(for: .seconds(30))
        throw DouyinAuthorizationError.qrCodeTimedOut
    }
}

@MainActor
private final class ExternalURLOpener: DouyinExternalURLOpening {
    private var results: [Bool]
    private(set) var openedURLs: [URL] = []

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return results.isEmpty ? false : results.removeFirst()
    }
}
