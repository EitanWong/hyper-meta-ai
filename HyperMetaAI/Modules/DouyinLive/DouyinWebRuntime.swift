import CoreImage
import Foundation
import SwiftUI
import WebKit
import os.log

private let douyinWebRuntimeLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "DouyinWebRuntime"
)

@MainActor
final class DouyinWebRuntime:
    NSObject,
    ObservableObject,
    DouyinLoginSession,
    DouyinAuthorizationPreparing,
    DouyinRequestExecuting
{
    @Published private(set) var isPageReady = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var appAuthorizationURL: URL?

    let webView: WKWebView

    var isAuthenticatedPage: Bool {
        Self.isAuthenticatedPageURL(currentURL, loginURL: loginURL)
    }

    static func isAuthenticatedPageURL(_ url: URL?, loginURL: URL) -> Bool {
        guard let url,
              url.host?.lowercased() == loginURL.host?.lowercased() else {
            return false
        }
        return !url.path.hasPrefix("/login")
    }

    private let loginURL: URL
    private let protectionConfiguration: DouyinWebProtectionConfiguration
    private var authorizationDiscoveryTask: Task<Void, Never>?
    private var navigationGeneration = 0
    private var appAuthorizationGeneration: Int?
    private var authorizationNavigationFailure: (generation: Int, message: String)?
    private var isAuthorizationPreparationActive = false
    private var cookieSyncGeneration: Int?
    private var protectionPreparationGeneration: Int?
    private var sdkGlueScriptSource: String?
    private var bdmsScriptSource: String?
    private var capturedPageMsToken: String?
    private var protectedEnvironmentOperation: (
        id: UUID,
        task: Task<Int, Error>
    )?

    init(
        loginURL: URL,
        protectionConfiguration: DouyinWebProtectionConfiguration
    ) {
        self.loginURL = loginURL
        self.protectionConfiguration = protectionConfiguration

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func prepareLogin() {
        guard webView.url == nil else { return }
        douyinWebRuntimeLogger.info("Loading Douyin login runtime")
        debugTrace("Loading login runtime: \(loginURL.absoluteString)")
        webView.load(URLRequest(url: loginURL))
    }

    func clearSession() async {
        protectedEnvironmentOperation?.task.cancel()
        protectedEnvironmentOperation = nil
        isAuthorizationPreparationActive = false
        authorizationDiscoveryTask?.cancel()
        appAuthorizationURL = nil
        appAuthorizationGeneration = nil
        authorizationNavigationFailure = nil
        capturedPageMsToken = nil
        let dataStore = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
        webView.load(URLRequest(url: loginURL))
    }

    func waitForAuthenticationCookies(
        attempts: Int = 30,
        interval: Duration = .milliseconds(500)
    ) async -> Bool {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for attempt in 0..<attempts {
            if await allCookies(in: cookieStore).contains(where: { cookie in
                ["sessionid", "sessionid_ss"].contains(cookie.name) && !cookie.value.isEmpty
            }) {
                debugTrace("Douyin authentication cookies are ready")
                return true
            }

            guard attempt + 1 < attempts, !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
        }
        debugTrace("Douyin authentication cookies did not become ready")
        return false
    }

    func prepareFreshAuthorization() async throws -> URL {
        protectedEnvironmentOperation?.task.cancel()
        protectedEnvironmentOperation = nil
        let baselineGeneration = navigationGeneration
        authorizationDiscoveryTask?.cancel()
        appAuthorizationURL = nil
        appAuthorizationGeneration = nil
        authorizationNavigationFailure = nil
        capturedPageMsToken = nil
        isAuthorizationPreparationActive = true
        defer {
            isAuthorizationPreparationActive = false
            authorizationDiscoveryTask?.cancel()
            if Task.isCancelled {
                webView.stopLoading()
            }
        }

        webView.stopLoading()
        var request = URLRequest(
            url: loginURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        debugTrace("Loading login page for a fresh QR authorization")
        guard webView.load(request) != nil else {
            throw DouyinAuthorizationError.loginPage("navigation unavailable")
        }

        for _ in 0..<120 {
            try Task.checkCancellation()
            if let appAuthorizationURL,
               let appAuthorizationGeneration,
               appAuthorizationGeneration > baselineGeneration {
                return appAuthorizationURL
            }
            if let failure = authorizationNavigationFailure,
               failure.generation > baselineGeneration {
                throw DouyinAuthorizationError.loginPage(failure.message)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        debugTrace("Timed out waiting for a fresh QR authorization")
        throw DouyinAuthorizationError.qrCodeTimedOut
    }

    func execute(_ request: DouyinHTTPRequest) async throws -> DouyinHTTPResponse {
        guard isPageReady, webView.url != nil else {
            douyinWebRuntimeLogger.error("Request bridge used before login runtime became ready")
            throw DouyinLiveError.loginPageUnavailable
        }

        let requestGeneration = try await prepareProtectedRequestEnvironment(requestURL: request.url)
        guard requestGeneration == navigationGeneration, isPageReady else {
            throw DouyinLiveError.loginPageUnavailable
        }
        let protectedRequestURL = try requestURLByApplyingCapturedPageToken(to: request.url)

        douyinWebRuntimeLogger.debug(
            "Executing protected request path=\(request.url.path, privacy: .public)"
        )

        let payload = JavaScriptRequest(
            method: request.method.rawValue,
            url: protectedRequestURL.absoluteString,
            headers: request.headers,
            body: request.body.flatMap { String(data: $0, encoding: .utf8) }
        )
        let encodedPayload = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: encodedPayload, encoding: .utf8) else {
            throw DouyinLiveError.invalidResponse("request bridge encoding")
        }

        let script = """
        const request = \(payloadJSON);
        try {
          const wireStartTime = performance.now();
          const response = await window.fetch(request.url, {
            method: request.method,
            headers: request.headers,
            body: request.body || undefined,
            credentials: "include",
            redirect: "follow"
          });
          const bytes = new Uint8Array(await response.arrayBuffer());
          let binary = "";
          const chunkSize = 0x8000;
          for (let index = 0; index < bytes.length; index += chunkSize) {
            const chunk = bytes.subarray(index, Math.min(index + chunkSize, bytes.length));
            binary += String.fromCharCode.apply(null, chunk);
          }
          const normalizePath = value => value.endsWith("/") ? value.slice(0, -1) : value;
          const expectedPath = normalizePath(new URL(request.url).pathname);
          const wireURL = performance.getEntriesByType("resource")
            .filter(entry => entry.startTime >= wireStartTime - 1)
            .filter(entry => {
              try {
                return normalizePath(new URL(entry.name).pathname) === expectedPath;
              } catch {
                return false;
              }
            })
            .sort((left, right) => right.startTime - left.startTime)[0]?.name || null;
          return JSON.stringify({
            statusCode: response.status,
            finalURL: response.url,
            wireURL,
            headers: Object.fromEntries(response.headers.entries()),
            bodyBase64: btoa(binary)
          });
        } catch (error) {
          return JSON.stringify({ bridgeError: String(error && error.message ? error.message : error) });
        }
        """

        let bridgeValue = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let bridgeJSON = bridgeValue as? String,
              let bridgeData = bridgeJSON.data(using: .utf8) else {
            throw DouyinLiveError.invalidResponse("request bridge result")
        }

        let bridgeResponse = try JSONDecoder().decode(JavaScriptResponse.self, from: bridgeData)
        if let bridgeError = bridgeResponse.bridgeError {
            douyinWebRuntimeLogger.error(
                "Request bridge failed path=\(request.url.path, privacy: .public) error=\(bridgeError, privacy: .public)"
            )
            debugTrace("Request bridge failed: \(request.url.path) - \(bridgeError)")
            throw DouyinLiveError.platform(bridgeError)
        }
        guard let statusCode = bridgeResponse.statusCode,
              let finalURLString = bridgeResponse.finalURL,
              let finalURL = URL(string: finalURLString),
              let bodyBase64 = bridgeResponse.bodyBase64,
              let body = Data(base64Encoded: bodyBase64) else {
            throw DouyinLiveError.invalidResponse("request bridge payload")
        }

        if finalURL.host == loginURL.host, finalURL.path.hasPrefix("/login") {
            debugTrace("Request redirected to login: \(request.url.path)")
            throw DouyinLiveError.sessionUnavailable
        }

        if request.requiresPlatformProtection {
            let protectionURL = bridgeResponse.wireURL.flatMap(URL.init(string:)) ?? finalURL
            let queryItems = URLComponents(
                url: protectionURL,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            let queryNames = Set(queryItems.map(\.name))
            guard queryNames.contains("a_bogus"), queryNames.contains("msToken") else {
                douyinWebRuntimeLogger.error(
                    "Request protection missing path=\(request.url.path, privacy: .public)"
                )
                debugTrace(
                    "Request protection missing: \(request.url.path) observed=\(queryNames.sorted())"
                )
                throw DouyinLiveError.requestProtectionUnavailable
            }
            debugTrace(
                "Request protection observed: \(request.url.path) query=\(queryNames.sorted())"
            )
        }

        douyinWebRuntimeLogger.debug(
            "Request bridge completed path=\(request.url.path, privacy: .public) status=\(statusCode)"
        )

        return DouyinHTTPResponse(
            statusCode: statusCode,
            finalURL: finalURL,
            headers: bridgeResponse.headers ?? [:],
            body: body
        )
    }
}

extension DouyinWebRuntime: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            return .allow
        }

        if !["http", "https", "about", "data", "blob"].contains(scheme) {
            let opened = await UIApplication.shared.open(url)
            debugTrace("External login scheme \(scheme) opened=\(opened)")
            return opened ? .cancel : .allow
        }

        if navigationAction.navigationType == .linkActivated,
           isDouyinUniversalLink(url),
           await UIApplication.shared.open(
               url,
               options: [.universalLinksOnly: true]
           ) {
            debugTrace("Douyin universal link opened in app: \(url.host ?? "unknown")\(url.path)")
            return .cancel
        }

        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        authorizationDiscoveryTask?.cancel()
        navigationGeneration &+= 1
        cookieSyncGeneration = nil
        protectionPreparationGeneration = nil
        appAuthorizationURL = nil
        appAuthorizationGeneration = nil
        authorizationNavigationFailure = nil
        isPageReady = false
        currentURL = webView.url
        douyinWebRuntimeLogger.debug("Login runtime navigation started")
        debugTrace("Navigation started: \(webView.url?.absoluteString ?? "unknown")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url
        isPageReady = true
        douyinWebRuntimeLogger.info(
            "Login runtime ready host=\(webView.url?.host ?? "unknown", privacy: .public)"
        )
        debugTrace("Navigation ready: \(webView.url?.absoluteString ?? "unknown")")
        if isAuthorizationPreparationActive {
            discoverAppAuthorizationURL(generation: navigationGeneration)
        }
        Task { await probePageProtectionRuntime() }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        currentURL = webView.url
        isPageReady = false
        recordNavigationFailure(error)
        douyinWebRuntimeLogger.error(
            "Login runtime navigation failed error=\(error.localizedDescription, privacy: .public)"
        )
        debugTrace("Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        currentURL = webView.url
        isPageReady = false
        recordNavigationFailure(error)
        douyinWebRuntimeLogger.error(
            "Login runtime provisional navigation failed error=\(error.localizedDescription, privacy: .public)"
        )
        debugTrace("Provisional navigation failed: \(error.localizedDescription)")
    }
}

extension DouyinWebRuntime: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let requestURL = navigationAction.request.url else { return nil }
        webView.load(URLRequest(url: requestURL))
        return nil
    }
}

private extension DouyinWebRuntime {
    func prepareProtectedRequestEnvironment(requestURL: URL) async throws -> Int {
        if let operation = protectedEnvironmentOperation {
            return try await operation.task.value
        }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw DouyinLiveError.loginPageUnavailable }
            return try await self.performProtectedRequestEnvironment(requestURL: requestURL)
        }
        protectedEnvironmentOperation = (operationID, task)
        defer {
            if protectedEnvironmentOperation?.id == operationID {
                protectedEnvironmentOperation = nil
            }
        }
        return try await task.value
    }

    func performProtectedRequestEnvironment(requestURL: URL) async throws -> Int {
        if webView.url?.host?.lowercased() != requestURL.host?.lowercased() {
            await synchronizeAuthenticationCookies(for: requestURL)
            if protectionConfiguration.reusesLoadedPageRuntime {
                try await navigateToPageProtectionOrigin(for: requestURL)
            } else {
                try await captureProtectionScriptSource()
                try await navigateToRequestOrigin(for: requestURL)
            }
        }

        let generation = navigationGeneration
        if cookieSyncGeneration != generation {
            await synchronizeAuthenticationCookies(for: requestURL)
            guard generation == navigationGeneration else {
                throw DouyinLiveError.loginPageUnavailable
            }
            cookieSyncGeneration = generation
        }

        if protectionPreparationGeneration != generation {
            try await initializePageProtection(for: requestURL)
            guard generation == navigationGeneration else {
                throw DouyinLiveError.loginPageUnavailable
            }
            protectionPreparationGeneration = generation
        }
        return generation
    }

    func captureProtectionScriptSource() async throws {
        let requiresPageToken = protectionConfiguration.capturesPageMsToken
        guard sdkGlueScriptSource == nil || bdmsScriptSource == nil
                || (requiresPageToken && capturedPageMsToken == nil) else { return }

        let discoveryScript = """
        const sources = [...document.scripts].map(script => script.src).filter(Boolean);
        const appID = \(protectionConfiguration.appID);
        const findMsToken = () => {
          const candidates = performance.getEntriesByType("resource")
          .map(entry => entry.name)
          .reverse()
          .map(name => {
            try {
              const url = new URL(name);
              const value = url.searchParams.get("msToken");
              return value ? { aid: url.searchParams.get("aid"), value } : null;
            } catch {
              return null;
            }
          })
          .filter(Boolean);
          return candidates.find(candidate => candidate.aid === String(appID))?.value || null;
        };
        let msToken = findMsToken();
        if (!msToken && \(requiresPageToken ? "true" : "false")) {
          try {
            const probeURL = new URL("/webcast/user/me/", location.origin);
            probeURL.searchParams.set("aid", String(appID));
            await fetch(probeURL, {
              method: "GET",
              credentials: "include",
              headers: { accept: "application/json, text/plain, */*" }
            });
            msToken = findMsToken();
          } catch {}
        }
        return JSON.stringify({
          glue: sources.find(source =>
            source.includes("/rc-client-security/web/glue/") &&
            new URL(source).pathname.endsWith("/sdk-glue.js")
          ) || null,
          bdms: sources.find(source =>
            source.includes("/rc-client-security/web/stable/") &&
            new URL(source).pathname.endsWith("/bdms.js")
          ) || null,
          msToken
        });
        """
        let value = try await webView.callAsyncJavaScript(
            discoveryScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let summary = value as? String,
              let summaryData = summary.data(using: .utf8),
              let sources = try? JSONDecoder().decode(ProtectionScriptURLs.self, from: summaryData),
              let glueURLString = sources.glue,
              let glueURL = URL(string: glueURLString),
              isTrustedProtectionScriptURL(glueURL, kind: .sdkGlue),
              let bdmsURLString = sources.bdms,
              let bdmsURL = URL(string: bdmsURLString),
              isTrustedProtectionScriptURL(bdmsURL, kind: .bdms),
              !requiresPageToken || sources.msToken.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) == true else {
            throw DouyinLiveError.requestProtectionUnavailable
        }

        sdkGlueScriptSource = try await downloadProtectionScript(
            from: glueURL,
            maximumSize: 500_000,
            requiredSymbol: "_SdkGlueInit"
        )
        bdmsScriptSource = try await downloadProtectionScript(
            from: bdmsURL,
            maximumSize: 2_000_000,
            requiredSymbol: "bdms"
        )
        capturedPageMsToken = requiresPageToken ? sources.msToken : nil
        debugTrace(
            "Captured trusted protection scripts glue=\(sdkGlueScriptSource?.utf8.count ?? 0) bdms=\(bdmsScriptSource?.utf8.count ?? 0) pageToken=\(capturedPageMsToken != nil)"
        )
    }

    func requestURLByApplyingCapturedPageToken(to requestURL: URL) throws -> URL {
        guard protectionConfiguration.capturesPageMsToken else { return requestURL }
        guard let capturedPageMsToken,
              var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "msToken" }) {
            queryItems.append(URLQueryItem(name: "msToken", value: capturedPageMsToken))
        }
        components.queryItems = queryItems
        guard let protectedURL = components.url else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        return protectedURL
    }

    func downloadProtectionScript(
        from sourceURL: URL,
        maximumSize: Int,
        requiredSymbol: String
    ) async throws -> String {
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/javascript", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= maximumSize,
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) != false,
              let source = String(data: data, encoding: .utf8),
              source.contains(requiredSymbol) else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        return source
    }

    func isTrustedProtectionScriptURL(_ url: URL, kind: ProtectionScriptKind) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        let trustedHost = ["bytetos.com", "yhgfb-cn-static.com", "bytegoofy.com"].contains {
            host == $0 || host.hasSuffix(".\($0)")
        }
        guard trustedHost else { return false }

        switch kind {
        case .sdkGlue:
            return url.path.hasPrefix("/obj/rc-client-security/web/glue/")
                && url.path.hasSuffix("/sdk-glue.js")
        case .bdms:
            return url.path.hasPrefix("/obj/rc-client-security/web/stable/")
                && url.path.hasSuffix("/bdms.js")
        }
    }

    func navigateToRequestOrigin(for requestURL: URL) async throws {
        guard let targetHost = requestURL.host?.lowercased(),
              let bootstrapURL = requestOriginBootstrapURL(for: requestURL) else {
            throw DouyinLiveError.invalidResponse("request origin")
        }

        let baselineGeneration = navigationGeneration
        debugTrace("Switching protected runtime to request origin host=\(targetHost)")
        guard webView.load(
            URLRequest(
                url: bootstrapURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 20
            )
        ) != nil else {
            throw DouyinLiveError.loginPageUnavailable
        }

        for _ in 0..<80 {
            try Task.checkCancellation()
            if navigationGeneration > baselineGeneration,
               isPageReady,
               webView.url?.host?.lowercased() == targetHost {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DouyinLiveError.loginPageUnavailable
    }

    func navigateToPageProtectionOrigin(for requestURL: URL) async throws {
        guard let targetHost = requestURL.host?.lowercased(),
              targetHost == loginURL.host?.lowercased() else {
            throw DouyinLiveError.invalidResponse("page protection origin")
        }

        let baselineGeneration = navigationGeneration
        debugTrace("Restoring official protection page host=\(targetHost)")
        guard webView.load(
            URLRequest(
                url: loginURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 20
            )
        ) != nil else {
            throw DouyinLiveError.loginPageUnavailable
        }

        for _ in 0..<80 {
            try Task.checkCancellation()
            if navigationGeneration > baselineGeneration,
               isPageReady,
               webView.url?.host?.lowercased() == targetHost {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DouyinLiveError.loginPageUnavailable
    }

    func requestOriginBootstrapURL(for requestURL: URL) -> URL? {
        guard var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/webcast/user/me/"
        components.fragment = nil
        return components.url
    }

    func synchronizeAuthenticationCookies(for requestURL: URL) async {
        guard let targetHost = requestURL.host?.lowercased(),
              targetHost == "amemv.com" || targetHost.hasSuffix(".amemv.com") else {
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await allCookies(in: cookieStore)
        let platformSuffixes = ["douyin.com", "amemv.com", "snssdk.com"]
        let candidates = cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return platformSuffixes.contains { domain == $0 || domain.hasSuffix(".\($0)") }
            }
            .sorted { left, right in
                cookiePriority(left, targetHost: targetHost) > cookiePriority(right, targetHost: targetHost)
            }

        var copiedNames = Set<String>()
        var copiedCount = 0
        for cookie in candidates where copiedNames.insert(cookie.name).inserted {
            guard let targetCookie = authenticationCookie(cookie, targetHost: targetHost) else { continue }
            await setCookie(targetCookie, in: cookieStore)
            copiedCount += 1
        }
        debugTrace("Authentication cookies synchronized count=\(copiedCount) target=\(targetHost)")
    }

    func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    func cookiePriority(_ cookie: HTTPCookie, targetHost: String) -> Int {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if domain == targetHost { return 3 }
        if targetHost.hasSuffix(".\(domain)") { return 2 }
        return 1
    }

    func authenticationCookie(_ cookie: HTTPCookie, targetHost: String) -> HTTPCookie? {
        var properties = cookie.properties ?? [:]
        properties[.domain] = targetHost
        properties[.path] = cookie.path.isEmpty ? "/" : cookie.path
        properties[.secure] = "TRUE"
        properties[HTTPCookiePropertyKey("SameSite")] = "None"
        properties.removeValue(forKey: .originURL)
        return HTTPCookie(properties: properties)
    }

    func initializePageProtection(for requestURL: URL) async throws {
        let appID = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "aid" })?
            .value
        guard let appID,
              let numericAppID = Int(appID),
              numericAppID == protectionConfiguration.appID else {
            throw DouyinLiveError.requestProtectionUnavailable
        }

        if protectionConfiguration.reusesLoadedPageRuntime {
            try await waitForLoadedPageProtection()
            return
        }

        guard let sdkGlueScriptSource, let bdmsScriptSource else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        let pathData = try JSONEncoder().encode(protectionConfiguration.protectedPaths)
        guard let protectedPathsJSON = String(data: pathData, encoding: .utf8) else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        let glueType = try await webView.callAsyncJavaScript(
            "return typeof globalThis._SdkGlueInit;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        if glueType != "function" {
            _ = try await webView.evaluateJavaScript(sdkGlueScriptSource)
        }
        let bdmsType = try await webView.callAsyncJavaScript(
            "return typeof globalThis.bdms;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        if bdmsType != "object" {
            _ = try await webView.evaluateJavaScript(bdmsScriptSource)
        }

        let script = """
        const appID = \(numericAppID);
        const pageID = \(protectionConfiguration.pageID);
        const protectedPaths = \(protectedPathsJSON);
        const protectionKey = `${appID}:${pageID}`;
        const markerName = "gfkadpd";
        const markerValue = `${appID},${pageID}`;
        try {
          const marker = document.cookie
            .split(";")
            .map(value => value.trim())
            .find(value => value.startsWith(`${markerName}=`))
            ?.slice(markerName.length + 1) || "";
          if (!marker.includes(markerValue)) {
            const nextMarker = marker ? `${markerValue}|${marker}` : markerValue;
            const expires = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toUTCString();
            document.cookie = `${markerName}=${nextMarker}; expires=${expires}; path=/; SameSite=None; Secure;`;
          }
          if (globalThis.__hyperMetaDouyinProtectionKey !== protectionKey &&
              typeof globalThis._SdkGlueInit === "function") {
            const bdmsOptions = {
                paths: { include: protectedPaths },
                ddrt: 3,
                aid: appID,
                pageId: pageID
            };
            const sdkInfo = {
              bdms: {
                init: options => globalThis.bdms.init(options),
                isLoaded: () => !!globalThis.bdms,
                srcList: []
              }
            };
            await Promise.resolve(globalThis._SdkGlueInit({
              self: { aid: appID, pageId: pageID },
              bdms: bdmsOptions
            }, sdkInfo));
            if (typeof globalThis.bdms === "object") {
              globalThis.__hyperMetaDouyinProtectionKey = protectionKey;
            }
          }
          return JSON.stringify({
            glue: typeof globalThis._SdkGlueInit,
            bdms: typeof globalThis.bdms,
            bdmsKeys: Object.keys(globalThis.bdms || {}).sort(),
            marker: document.cookie.split(";").some(value =>
              value.trim().startsWith(`${markerName}=${markerValue}`)
            ),
            initialized: globalThis.__hyperMetaDouyinProtectionKey === protectionKey
          });
        } catch (error) {
          return JSON.stringify({
            error: String(error && error.message ? error.message : error),
            glue: typeof globalThis._SdkGlueInit,
            bdms: typeof globalThis.bdms
          });
        }
        """

        let value = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let summary = value as? String,
              summary.contains("\"initialized\":true") else {
            debugTrace("Page protection preparation incomplete: \(value as? String ?? "invalid result")")
            throw DouyinLiveError.requestProtectionUnavailable
        }
        debugTrace("Page protection prepared: \(summary)")
    }

    func waitForLoadedPageProtection() async throws {
        let expectedMarker = "\(protectionConfiguration.appID),\(protectionConfiguration.pageID)"
        let script = """
        const expectedMarker = \(try javaScriptString(expectedMarker));
        const marker = document.cookie
          .split(";")
          .map(value => value.trim())
          .find(value => value.startsWith("gfkadpd="))
          ?.slice("gfkadpd=".length) || "";
        const ready = marker.includes(expectedMarker) &&
          typeof globalThis._SdkGlueInit === "function" &&
          typeof globalThis.bdms === "object" &&
          typeof globalThis.bdms.init === "function";
        return JSON.stringify({
          ready,
          marker: marker.includes(expectedMarker),
          glue: typeof globalThis._SdkGlueInit,
          bdms: typeof globalThis.bdms,
          bdmsInit: typeof globalThis.bdms?.init
        });
        """

        for attempt in 0..<40 {
            try Task.checkCancellation()
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            if let summary = value as? String, summary.contains("\"ready\":true") {
                debugTrace("Official page protection ready: \(summary)")
                return
            }
            guard attempt + 1 < 40 else { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DouyinLiveError.requestProtectionUnavailable
    }

    func javaScriptString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DouyinLiveError.requestProtectionUnavailable
        }
        return encoded
    }

    func discoverAppAuthorizationURL(generation: Int) {
        authorizationDiscoveryTask?.cancel()
        guard webView.url?.path.hasPrefix("/login") == true else {
            appAuthorizationURL = nil
            appAuthorizationGeneration = nil
            return
        }

        authorizationDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            var observedSources = Set<String>()
            for _ in 0..<240 {
                guard !Task.isCancelled,
                      self.navigationGeneration == generation,
                      self.webView.url?.path.hasPrefix("/login") == true else {
                    return
                }
                if let sources = await self.loginQRCodeImageSources() {
                    for source in sources where observedSources.insert(source).inserted {
                        if let url = await self.qrCodePayloadURL(from: source) {
                            guard !Task.isCancelled,
                                  self.navigationGeneration == generation else { return }
                            guard DouyinAuthorizationRouteBuilder.canRoute(url) else { continue }
                            self.appAuthorizationURL = url
                            self.appAuthorizationGeneration = generation
                            self.debugTrace(
                                "QR authorization ready scheme=\(url.scheme ?? "unknown") host=\(url.host ?? "none") path=\(url.path)"
                            )
                            return
                        }
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    func recordNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        authorizationNavigationFailure = (
            generation: navigationGeneration,
            message: error.localizedDescription
        )
    }

    func loginQRCodeImageSources() async -> [String]? {
        let script = """
        const sources = [...document.querySelectorAll("img")]
          .filter(image => {
            const label = `${image.getAttribute("aria-label") || ""} ${image.className || ""}`;
            return /二维码|qrcode|qr_code/i.test(label) || image.src.startsWith("data:image");
          })
          .map(image => image.src)
          .filter(Boolean)
          .slice(0, 8);
        return JSON.stringify(sources);
        """
        guard let value = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ), let json = value as? String, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    func qrCodePayloadURL(from source: String) async -> URL? {
        guard source.utf8.count <= 4_000_000 else { return nil }

        let imageData: Data?
        if source.hasPrefix("data:image"),
           let comma = source.firstIndex(of: ",") {
            imageData = Data(base64Encoded: String(source[source.index(after: comma)...]))
        } else if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: request),
               data.count <= 4_000_000,
               (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) != false {
                imageData = data
            } else {
                imageData = nil
            }
        } else {
            imageData = nil
        }

        guard let imageData,
              imageData.count <= 4_000_000,
              let image = CIImage(data: imageData),
              let detector = CIDetector(
                  ofType: CIDetectorTypeQRCode,
                  context: nil,
                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ),
              let payload = detector.features(in: image)
                  .compactMap({ ($0 as? CIQRCodeFeature)?.messageString })
                  .first,
              payload.utf8.count <= 8_192,
              let url = URL(string: payload),
              url.scheme != nil else {
            return nil
        }
        return url
    }

    func isDouyinUniversalLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host != loginURL.host else { return false }
        return host == "douyin.com" || host.hasSuffix(".douyin.com")
    }

    func probePageProtectionRuntime() async {
        #if DEBUG
        let script = """
        const acrawler = globalThis.byted_acrawler;
        const acrawlerMembers = acrawler && typeof acrawler === "object"
          ? [...new Set([
              ...Object.getOwnPropertyNames(acrawler),
              ...Object.getOwnPropertyNames(Object.getPrototypeOf(acrawler) || {})
            ])]
              .sort()
              .map(name => ({ name, type: typeof acrawler[name] }))
          : [];
        let acrawlerSign = null;
        if (acrawler && typeof acrawler.sign === "function") {
          try {
            const result = await Promise.resolve(acrawler.sign({
              url: "https://webcast.amemv.com/webcast/user/me/?aid=2079"
            }));
            acrawlerSign = typeof result === "string"
              ? { type: "string", length: result.length }
              : {
                  type: typeof result,
                  keys: result && typeof result === "object" ? Object.keys(result).sort() : []
                };
          } catch (error) {
            acrawlerSign = { error: String(error && error.message ? error.message : error) };
          }
        }
        let sameOriginProbe = null;
        if (location.host === "anchor.douyin.com") {
          try {
            const probeURL = new URL("/webcast/user/me/", location.origin);
            probeURL.searchParams.set("aid", "477650");
            const response = await fetch(probeURL, {
              method: "GET",
              credentials: "include",
              headers: { accept: "application/json, text/plain, */*" }
            });
            const body = await response.text();
            const finalURL = new URL(response.url);
            const observedQueryNames = performance.getEntriesByType("resource")
              .map(entry => entry.name)
              .filter(name => name.includes("/webcast/user/me/"))
              .flatMap(name => {
                try { return [...new URL(name).searchParams.keys()]; } catch { return []; }
              });
            sameOriginProbe = {
              status: response.status,
              finalPath: finalURL.pathname,
              contentType: response.headers.get("content-type") || "",
              bodyKind: body.trimStart().startsWith("{") ? "json" : "other",
              queryNames: [...new Set(observedQueryNames)].sort()
            };
          } catch (error) {
            sameOriginProbe = { error: String(error && error.message ? error.message : error) };
          }
        }
        return JSON.stringify({
          sdkGlue: typeof globalThis._SdkGlueInit,
          bdms: typeof globalThis.bdms,
          acrawler: typeof globalThis.byted_acrawler,
          acrawlerMembers,
          acrawlerSign,
          sameOriginProbe,
          cookieNames: document.cookie
            .split(";")
            .map(value => value.split("=", 1)[0].trim())
            .filter(Boolean)
            .sort(),
          securityResources: performance.getEntriesByType("resource")
            .map(entry => entry.name)
            .filter(name => /bdms|secsdk|sdk-glue|security/i.test(name))
            .map(name => {
              try { return new URL(name).pathname; } catch { return name; }
            })
            .slice(0, 20),
          scriptPaths: [...document.scripts]
            .map(script => script.src)
            .filter(Boolean)
            .map(value => {
              try { return new URL(value).pathname; } catch { return value; }
            })
            .slice(0, 20),
          loginActions: [...document.querySelectorAll("button, a, [role=button]")]
            .filter(element => {
              const style = getComputedStyle(element);
              const rect = element.getBoundingClientRect();
              return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
            })
            .map(element => (element.innerText || element.textContent || "").trim().replace(/\\s+/g, " "))
            .filter(Boolean)
            .map(value => value.slice(0, 40))
            .slice(0, 20),
          linkTargets: [...document.querySelectorAll("a[href]")]
            .map(element => element.href)
            .filter(Boolean)
            .map(value => {
              try {
                const url = new URL(value);
                return { scheme: url.protocol.replace(":", ""), host: url.host, path: url.pathname };
              } catch {
                return { scheme: "invalid", host: "", path: "" };
              }
            })
            .slice(0, 20)
        });
        """
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            debugTrace("Page protection probe: \(value as? String ?? "invalid result")")
        } catch {
            debugTrace("Page protection probe failed: \(error.localizedDescription)")
        }
        #endif
    }

    func debugTrace(_ message: String) {
        #if DEBUG
        print("[DouyinLiveDebug] \(message)")
        #endif
    }

    struct JavaScriptRequest: Encodable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: String?
    }

    struct JavaScriptResponse: Decodable {
        let statusCode: Int?
        let finalURL: String?
        let wireURL: String?
        let headers: [String: String]?
        let bodyBase64: String?
        let bridgeError: String?
    }

    struct ProtectionScriptURLs: Decodable {
        let glue: String?
        let bdms: String?
        let msToken: String?
    }

    enum ProtectionScriptKind {
        case sdkGlue
        case bdms
    }
}

struct DouyinLoginWebView: UIViewRepresentable {
    let runtime: DouyinWebRuntime

    func makeUIView(context: Context) -> WKWebView {
        runtime.prepareLogin()
        return runtime.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
