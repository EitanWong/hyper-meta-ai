import AVFoundation
import XCTest
@testable import HyperMetaAI

final class VoiceAudioFrontEndContractTests: XCTestCase {
  func testSpeechRecognitionFrontEndEnablesAppleProcessingAndAGC() {
    let configuration = AppleVoiceAudioFrontEnd.configuration

    XCTAssertTrue(configuration.voiceProcessingEnabled)
    XCTAssertTrue(configuration.echoCancellationEnabled)
    XCTAssertTrue(configuration.adaptiveNoiseReductionEnabled)
    XCTAssertTrue(configuration.automaticGainControlEnabled)
    XCTAssertFalse(configuration.processingBypassed)
  }

  func testGlassesHFPIsPreferredAsAFullDuplexEndpoint() {
    let decision = VoiceAudioRoutePolicy.decide(
      availableInputs: [
        VoiceAudioInputCandidate(id: "iphone", kind: .builtIn),
        VoiceAudioInputCandidate(id: "rayban", kind: .bluetoothHFP),
      ],
      currentInput: VoiceAudioInputCandidate(id: "iphone", kind: .builtIn),
      preference: .bluetoothWhenAvailable
    )

    XCTAssertEqual(decision.preferredInputID, "rayban")
    XCTAssertFalse(decision.forcesBuiltInSpeaker)
  }

  func testStandaloneAppUsesBuiltInMicAndLoudspeaker() {
    let phone = VoiceAudioInputCandidate(id: "iphone", kind: .builtIn)
    let decision = VoiceAudioRoutePolicy.decide(
      availableInputs: [phone],
      currentInput: phone,
      preference: .bluetoothWhenAvailable
    )

    XCTAssertNil(decision.preferredInputID)
    XCTAssertTrue(decision.forcesBuiltInSpeaker)
  }

  func testPhoneMicPreferenceOverridesConnectedBluetoothInput() {
    let decision = VoiceAudioRoutePolicy.decide(
      availableInputs: [
        VoiceAudioInputCandidate(id: "rayban", kind: .bluetoothHFP),
        VoiceAudioInputCandidate(id: "iphone", kind: .builtIn),
      ],
      currentInput: VoiceAudioInputCandidate(id: "rayban", kind: .bluetoothHFP),
      preference: .builtIn
    )

    XCTAssertEqual(decision.preferredInputID, "iphone")
    XCTAssertTrue(decision.forcesBuiltInSpeaker)
  }

  func testWiredVoiceRouteIsNotReplacedByPhoneSpeaker() {
    let wired = VoiceAudioInputCandidate(id: "headset", kind: .wired)
    let decision = VoiceAudioRoutePolicy.decide(
      availableInputs: [wired],
      currentInput: wired,
      preference: .bluetoothWhenAvailable
    )

    XCTAssertNil(decision.preferredInputID)
    XCTAssertFalse(decision.forcesBuiltInSpeaker)
  }

  func testDirectionalPolicyPrefersFrontCardioidMicrophone() {
    let decision = VoiceAudioDataSourcePolicy.decide(availableDataSources: [
      VoiceAudioDataSourceCandidate(
        id: "bottom",
        isFrontFacing: false,
        supportedPatterns: [.cardioid]
      ),
      VoiceAudioDataSourceCandidate(
        id: "front",
        isFrontFacing: true,
        supportedPatterns: [.cardioid]
      ),
    ])

    XCTAssertEqual(
      decision,
      VoiceAudioDataSourceDecision(id: "front", polarPattern: .cardioid)
    )
  }

  func testDirectionalPolicyFallsBackToSubcardioidWhenNeeded() {
    let decision = VoiceAudioDataSourcePolicy.decide(availableDataSources: [
      VoiceAudioDataSourceCandidate(
        id: "front",
        isFrontFacing: true,
        supportedPatterns: [.subcardioid]
      )
    ])

    XCTAssertEqual(
      decision,
      VoiceAudioDataSourceDecision(id: "front", polarPattern: .subcardioid)
    )
  }

  func testEverySpeechInputProfileRequiresVoiceProcessing() {
    XCTAssertTrue(AudioSessionProfile.voiceChat.usesVoiceProcessing)
    XCTAssertTrue(AudioSessionProfile.translation(usePhoneMic: true).usesVoiceProcessing)
    XCTAssertTrue(AudioSessionProfile.translation(usePhoneMic: false).usesVoiceProcessing)
    XCTAssertFalse(AudioSessionProfile.playback.usesVoiceProcessing)
  }
}

final class SpeechRecognitionAccuracyEvaluatorTests: XCTestCase {
  func testChineseCorpusPassesHighAccuracyCERGate() {
    let report = SpeechRecognitionAccuracyEvaluator.evaluate(
      [
        SpeechRecognitionSample(
          reference: "你好千问请帮我查询明天上海的天气",
          hypothesis: "你好千问请帮我查询明天上海的天气"
        ),
        SpeechRecognitionSample(
          reference: "提醒我晚上八点给妈妈打电话",
          hypothesis: "提醒我晚上八点给妈妈打电化"
        ),
      ],
      tokenization: .characters
    )

    XCTAssertEqual(report.errorCount, 1)
    XCTAssertTrue(report.meets(
      minimumAccuracy: SpeechRecognitionAccuracyEvaluator.minimumCharacterAccuracy
    ))
  }

  func testEnglishCorpusPassesHighAccuracyWERGate() {
    let report = SpeechRecognitionAccuracyEvaluator.evaluate(
      [SpeechRecognitionSample(
        reference: "please remind me to call the design team tomorrow morning",
        hypothesis: "please remind me to call design team tomorrow morning"
      )],
      tokenization: .words
    )

    XCTAssertEqual(report.errorCount, 1)
    XCTAssertTrue(report.meets(
      minimumAccuracy: SpeechRecognitionAccuracyEvaluator.minimumWordAccuracy
    ))
  }

  func testLowAccuracyCorpusFailsTheQualityGate() {
    let report = SpeechRecognitionAccuracyEvaluator.evaluate(
      [SpeechRecognitionSample(
        reference: "打开日历并创建明天上午九点的会议",
        hypothesis: "播放音乐"
      )],
      tokenization: .characters
    )

    XCTAssertFalse(report.meets(
      minimumAccuracy: SpeechRecognitionAccuracyEvaluator.minimumCharacterAccuracy
    ))
  }

  func testPunctuationAndCaseDoNotCountAsRecognitionErrors() {
    let report = SpeechRecognitionAccuracyEvaluator.evaluate(
      [SpeechRecognitionSample(
        reference: "Hello, Ray-Ban!",
        hypothesis: "hello ray ban"
      )],
      tokenization: .words
    )

    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(report.accuracy, 1)
  }

  func testEmptyCorpusCannotPassTheQualityGate() {
    let report = SpeechRecognitionAccuracyEvaluator.evaluate([], tokenization: .characters)

    XCTAssertFalse(report.meets(
      minimumAccuracy: SpeechRecognitionAccuracyEvaluator.minimumCharacterAccuracy
    ))
  }
}

private final class VoiceAudioHardwareSocket: QwenGatewaySocket {
  private var receiveCompletion: ((Result<String, Error>) -> Void)?

  func send(_ string: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  func receive(completion: @escaping (Result<String, Error>) -> Void) {
    receiveCompletion = completion
  }

  func close() {
    receiveCompletion = nil
  }
}

private final class VoiceAudioHardwarePlayback: RealtimeAudioPlaybackControlling {
  func start(
    generation: Int,
    onFailure: @escaping RealtimeAudioPlaybackPipeline.FailureHandler,
    onResponsePlaybackComplete: @escaping RealtimeAudioPlaybackPipeline.PlaybackCompletionHandler,
    onAudioLevel: @escaping RealtimeAudioPlaybackPipeline.AudioLevelHandler
  ) {}

  func prepare(generation: Int) {}
  func stop() {}

  func enqueue(
    _ data: Data,
    generation: Int,
    receivedAt: TimeInterval
  ) -> RealtimeAudioJitterOfferResult {
    .inactive
  }

  func finishResponse(generation: Int) {}
  @discardableResult
  func interrupt(generation: Int) -> Int { 0 }
  @discardableResult
  func invalidateAudioSystem(generation: Int) -> Int { 0 }
}

final class VoiceAudioFrontEndHardwareTests: XCTestCase {
  func testPhysicalDeviceStartsProcessedCaptureAndNeverUsesReceiver() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Voice Processing I/O requires physical audio hardware.")
    #else
    guard AVAudioApplication.shared.recordPermission == .granted else {
      throw XCTSkip("Grant microphone access to the test host before hardware validation.")
    }

    let session = AVAudioSession.sharedInstance()
    try await AudioSessionCoordinator.shared.activateAsync(.qwenVoice, profile: .voiceChat)
    let engine = AVAudioEngine()
    var tapInstalled = false
    defer {
      if tapInstalled {
        engine.inputNode.removeTap(onBus: 0)
      }
      engine.stop()
      AudioSessionCoordinator.shared.deactivateAsync(.qwenVoice)
    }

    let status = try AppleVoiceAudioFrontEnd.configure(engine)
    XCTAssertTrue(status.voiceProcessingEnabled)
    XCTAssertTrue(status.automaticGainControlEnabled)
    XCTAssertFalse(status.processingBypassed)

    let receivedInput = expectation(description: "processed microphone input")
    receivedInput.assertForOverFulfill = false
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      if buffer.frameLength > 0 {
        receivedInput.fulfill()
      }
    }
    tapInstalled = true
    engine.prepare()
    try engine.start()

    await fulfillment(of: [receivedInput], timeout: 2)
    let routeDescription = session.currentRoute.outputs.map {
      "\($0.portName)[\($0.portType.rawValue)]"
    }.joined(separator: ",")
    print("[VoiceAudioHardware] output=\(routeDescription)")
    let routeAttachment = XCTAttachment(string: routeDescription)
    routeAttachment.name = "Voice audio output route"
    routeAttachment.lifetime = .keepAlways
    add(routeAttachment)
    XCTAssertEqual(session.mode, .voiceChat)
    XCTAssertFalse(session.currentRoute.outputs.contains(where: {
      $0.portType == .builtInReceiver
    }))
    XCTAssertTrue(session.currentRoute.outputs.contains(where: {
      switch $0.portType {
      case .builtInSpeaker, .bluetoothHFP, .headphones, .usbAudio, .lineOut:
        return true
      default:
        return false
      }
    }))
    #endif
  }

  @MainActor
  func testQwenCaptureRebuildsAfterAudioEngineConfigurationChange() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Voice Processing I/O requires physical audio hardware.")
    #else
    guard AVAudioApplication.shared.recordPermission == .granted else {
      throw XCTSkip("Grant microphone access to the test host before hardware validation.")
    }

    let socket = VoiceAudioHardwareSocket()
    let gateway = QwenGatewayService(socketFactory: { _ in socket })
    gateway.mode = .external
    let qwenSession = QwenVoiceSession(
      gateway: gateway,
      audioPlaybackPipeline: VoiceAudioHardwarePlayback()
    )
    defer {
      qwenSession.stop()
      gateway.disconnect()
    }

    qwenSession.start()
    await waitUntil(timeout: 3) { qwenSession.isCaptureEngineRunning }
    XCTAssertTrue(qwenSession.isCaptureEngineRunning)
    let runningGeneration = qwenSession.captureGeneration

    qwenSession.handleAudioEngineConfigurationChange()

    XCTAssertFalse(qwenSession.isCaptureEngineRunning)
    XCTAssertEqual(qwenSession.captureGeneration, runningGeneration + 1)
    await waitUntil(timeout: 3) {
      qwenSession.isCaptureEngineRunning
        && qwenSession.captureGeneration > runningGeneration + 1
    }
    XCTAssertTrue(qwenSession.isCaptureEngineRunning)
    #endif
  }

  @MainActor
  private func waitUntil(
    timeout: TimeInterval,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}
