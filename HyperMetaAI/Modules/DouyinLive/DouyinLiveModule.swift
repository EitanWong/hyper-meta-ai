import SwiftUI

enum DouyinLiveModule {
    typealias RequestExecutorFactory = @MainActor (DouyinWebRuntime) -> any DouyinRequestExecuting

    @MainActor
    static func makeView(
        streamViewModel: StreamSessionViewModel,
        configuration: DouyinLiveConfiguration = DouyinLiveConfiguration(),
        requestExecutorFactory: RequestExecutorFactory? = nil
    ) -> DouyinLiveView {
        let runtime = DouyinWebRuntime(
            loginURL: configuration.loginURL,
            protectionConfiguration: configuration.requestProfile.webProtection
        )
        let requestExecutor: any DouyinRequestExecuting
        if let requestExecutorFactory {
            requestExecutor = requestExecutorFactory(runtime)
        } else {
            requestExecutor = runtime
        }
        let apiClient = DouyinWebcastAPIClient(
            configuration: configuration,
            executor: requestExecutor
        )
        let messages = DouyinPollingMessageClient(
            configuration: configuration,
            executor: requestExecutor
        )
        let publisher = DouyinRTMPPublisher()
        let frameSource = MetaRaybanDouyinFrameSource(streamViewModel: streamViewModel)
        let coordinator = DouyinLiveCoordinator(
            configuration: configuration,
            loginSession: runtime,
            accountReader: apiClient,
            roomPreparer: apiClient,
            roomLifecycle: apiClient,
            metricsReader: apiClient,
            messages: messages,
            publisher: publisher,
            frameSource: frameSource
        )
        return DouyinLiveView(
            streamViewModel: streamViewModel,
            coordinator: coordinator,
            runtime: runtime
        )
    }
}
