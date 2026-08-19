/*
 * Audio Session Coordinator
 * Serializes process-wide AVAudioSession ownership across realtime features.
 */

import AVFoundation
import Foundation

struct VoiceAudioFrontEndConfiguration: Equatable, Sendable {
    let voiceProcessingEnabled: Bool
    let automaticGainControlEnabled: Bool
    let processingBypassed: Bool

    static let speechRecognition = VoiceAudioFrontEndConfiguration(
        voiceProcessingEnabled: true,
        automaticGainControlEnabled: true,
        processingBypassed: false
    )

    var echoCancellationEnabled: Bool {
        voiceProcessingEnabled && !processingBypassed
    }

    var adaptiveNoiseReductionEnabled: Bool {
        voiceProcessingEnabled && !processingBypassed
    }
}

struct VoiceAudioFrontEndStatus: Equatable, Sendable {
    let voiceProcessingEnabled: Bool
    let automaticGainControlEnabled: Bool
    let processingBypassed: Bool
}

enum VoiceAudioFrontEndError: LocalizedError {
    case engineMustBeStopped
    case configurationDidNotApply
    case inputFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .engineMustBeStopped:
            return "Voice processing must be configured before the audio engine starts."
        case .configurationDidNotApply:
            return "Apple voice processing could not be enabled for the current audio route."
        case .inputFormatUnavailable:
            return "The current audio route does not provide a usable microphone format."
        }
    }
}

enum AppleVoiceAudioFrontEnd {
    static let configuration = VoiceAudioFrontEndConfiguration.speechRecognition

    /// Voice Processing I/O supplies Apple's echo cancellation and adaptive voice
    /// processing. AGC remains explicit so every capture path has the same contract.
    @discardableResult
    static func configure(_ engine: AVAudioEngine) throws -> VoiceAudioFrontEndStatus {
        guard !engine.isRunning else {
            throw VoiceAudioFrontEndError.engineMustBeStopped
        }

        let inputNode = engine.inputNode
        if !inputNode.isVoiceProcessingEnabled {
            try inputNode.setVoiceProcessingEnabled(true)
        }
        inputNode.isVoiceProcessingBypassed = false
        inputNode.isVoiceProcessingAGCEnabled = true
        inputNode.isVoiceProcessingInputMuted = false

        let status = VoiceAudioFrontEndStatus(
            voiceProcessingEnabled: inputNode.isVoiceProcessingEnabled,
            automaticGainControlEnabled: inputNode.isVoiceProcessingAGCEnabled,
            processingBypassed: inputNode.isVoiceProcessingBypassed
        )
        guard status.voiceProcessingEnabled,
              status.automaticGainControlEnabled,
              !status.processingBypassed else {
            throw VoiceAudioFrontEndError.configurationDidNotApply
        }
        return status
    }
}

enum VoiceAudioInputKind: Equatable, Sendable {
    case builtIn
    case bluetoothHFP
    case wired
    case usb
    case other

    var keepsExternalOutput: Bool {
        switch self {
        case .bluetoothHFP, .wired, .usb, .other:
            return true
        case .builtIn:
            return false
        }
    }
}

struct VoiceAudioInputCandidate: Equatable, Sendable {
    let id: String
    let kind: VoiceAudioInputKind
}

enum VoiceAudioInputPreference: Equatable, Sendable {
    case bluetoothWhenAvailable
    case builtIn
}

struct VoiceAudioRouteDecision: Equatable, Sendable {
    let preferredInputID: String?
    let forcesBuiltInSpeaker: Bool
}

enum VoiceAudioRoutePolicy {
    static func decide(
        availableInputs: [VoiceAudioInputCandidate],
        currentInput: VoiceAudioInputCandidate?,
        preference: VoiceAudioInputPreference
    ) -> VoiceAudioRouteDecision {
        switch preference {
        case .builtIn:
            return VoiceAudioRouteDecision(
                preferredInputID: availableInputs.first(where: { $0.kind == .builtIn })?.id,
                forcesBuiltInSpeaker: true
            )
        case .bluetoothWhenAvailable:
            if let bluetooth = availableInputs.first(where: { $0.kind == .bluetoothHFP }) {
                return VoiceAudioRouteDecision(
                    preferredInputID: bluetooth.id,
                    forcesBuiltInSpeaker: false
                )
            }
            return VoiceAudioRouteDecision(
                preferredInputID: nil,
                forcesBuiltInSpeaker: currentInput?.kind.keepsExternalOutput != true
            )
        }
    }
}

enum VoiceAudioPolarPattern: Equatable, Sendable {
    case cardioid
    case subcardioid
}

struct VoiceAudioDataSourceCandidate: Equatable, Sendable {
    let id: String
    let isFrontFacing: Bool
    let supportedPatterns: [VoiceAudioPolarPattern]
}

struct VoiceAudioDataSourceDecision: Equatable, Sendable {
    let id: String
    let polarPattern: VoiceAudioPolarPattern
}

enum VoiceAudioDataSourcePolicy {
    static func decide(
        availableDataSources: [VoiceAudioDataSourceCandidate]
    ) -> VoiceAudioDataSourceDecision? {
        for pattern in [VoiceAudioPolarPattern.cardioid, .subcardioid] {
            let matches = availableDataSources.filter { $0.supportedPatterns.contains(pattern) }
            if let selected = matches.first(where: \.isFrontFacing) ?? matches.first {
                return VoiceAudioDataSourceDecision(id: selected.id, polarPattern: pattern)
            }
        }
        return nil
    }
}

enum AudioSessionOwner: Hashable, Sendable {
    case liveAI
    case liveTranslate
    case openClawASR
    case qwenVoice
    case textToSpeech
}

enum AudioSessionProfile: Hashable, Sendable {
    case voiceChat
    case translation(usePhoneMic: Bool)
    case playback

    var requiresExclusiveInput: Bool {
        switch self {
        case .voiceChat, .translation:
            return true
        case .playback:
            return false
        }
    }

    var usesVoiceProcessing: Bool {
        switch self {
        case .voiceChat, .translation:
            return true
        case .playback:
            return false
        }
    }

    var inputPreference: VoiceAudioInputPreference? {
        switch self {
        case .voiceChat, .translation(usePhoneMic: false):
            return .bluetoothWhenAvailable
        case .translation(usePhoneMic: true):
            return .builtIn
        case .playback:
            return nil
        }
    }
}

enum AudioSessionCoordinatorError: LocalizedError {
    case inputAlreadyInUse

    var errorDescription: String? {
        switch self {
        case .inputAlreadyInUse:
            return "Another feature is currently using the microphone."
        }
    }
}

enum AudioSessionRouteAction: Equatable {
    case none
    case apply(AudioSessionProfile)
    case deactivate
}

struct AudioSessionClaimRegistry {
    private(set) var claims: [AudioSessionOwner: AudioSessionProfile] = [:]

    mutating func activate(
        _ owner: AudioSessionOwner,
        profile: AudioSessionProfile
    ) throws -> AudioSessionRouteAction {
        if claims[owner] == profile {
            return .none
        }

        if profile.requiresExclusiveInput,
           claims.contains(where: { $0.key != owner && $0.value.requiresExclusiveInput }) {
            throw AudioSessionCoordinatorError.inputAlreadyInUse
        }

        let previousProfile = preferredProfile
        claims[owner] = profile
        guard preferredProfile != previousProfile, let preferredProfile else {
            return .none
        }
        return .apply(preferredProfile)
    }

    mutating func deactivate(_ owner: AudioSessionOwner) -> AudioSessionRouteAction {
        let previousProfile = preferredProfile
        guard claims.removeValue(forKey: owner) != nil else {
            return .none
        }
        guard let preferredProfile else {
            return .deactivate
        }
        return preferredProfile == previousProfile ? .none : .apply(preferredProfile)
    }

    var preferredProfile: AudioSessionProfile? {
        if claims.values.contains(.voiceChat) {
            return .voiceChat
        }
        if let translation = claims.values.first(where: {
            if case .translation = $0 { return true }
            return false
        }) {
            return translation
        }
        return claims.isEmpty ? nil : .playback
    }
}

final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private let lock = NSLock()
    private let controlQueue = DispatchQueue(
        label: "com.lunflux.hyper-meta-ai.audio-session-control",
        qos: .userInitiated
    )
    private var claimRegistry = AudioSessionClaimRegistry()

    private init() {}

    func activate(_ owner: AudioSessionOwner, profile: AudioSessionProfile) throws {
        lock.lock()
        defer { lock.unlock() }

        let previousRegistry = claimRegistry
        let action = try claimRegistry.activate(owner, profile: profile)
        guard action != .none else { return }

        do {
            try apply(action)
        } catch {
            // Claim updates and AVAudioSession configuration form one logical
            // transaction. A failed configuration must not leave a phantom
            // microphone owner that blocks every later feature.
            claimRegistry = previousRegistry
            restoreTrackedAudioSession()
            throw error
        }
    }

    func activateAsync(_ owner: AudioSessionOwner, profile: AudioSessionProfile) async throws {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { [self] in
                do {
                    try activate(owner, profile: profile)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deactivate(_ owner: AudioSessionOwner) {
        lock.lock()
        defer { lock.unlock() }

        let previousRegistry = claimRegistry
        let action = claimRegistry.deactivate(owner)
        guard action != .none else { return }

        do {
            try apply(action)
        } catch {
            claimRegistry = previousRegistry
            restoreTrackedAudioSession()
            print("[AudioSession] Failed to update audio ownership: \(error.localizedDescription)")
        }
    }

    func deactivateAsync(_ owner: AudioSessionOwner) {
        controlQueue.async { [self] in
            deactivate(owner)
        }
    }

    private func apply(_ action: AudioSessionRouteAction) throws {
        switch action {
        case .none:
            return
        case .apply(let profile):
            try applyActiveProfile(profile)
        case .deactivate:
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func applyActiveProfile(_ profile: AudioSessionProfile) throws {
        let audioSession = AVAudioSession.sharedInstance()

        switch profile {
        case .voiceChat:
            try setVoiceCategory(on: audioSession, allowsBluetoothInput: true)
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setPreferredIOBufferDuration(0.01)
        case .translation(let usePhoneMic):
            try setVoiceCategory(on: audioSession, allowsBluetoothInput: !usePhoneMic)
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setPreferredIOBufferDuration(0.01)
        case .playback:
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
        }

        try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
        if let inputPreference = profile.inputPreference {
            try applyVoiceRoute(inputPreference, to: audioSession)
        }
    }

    private func setVoiceCategory(
        on audioSession: AVAudioSession,
        allowsBluetoothInput: Bool
    ) throws {
        var options: AVAudioSession.CategoryOptions = []
        if allowsBluetoothInput {
            options.insert(.allowBluetoothHFP)
        }

        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
    }

    private func applyVoiceRoute(
        _ preference: VoiceAudioInputPreference,
        to audioSession: AVAudioSession
    ) throws {
        let availablePorts = audioSession.availableInputs ?? []
        let candidates = availablePorts.map(Self.candidate(for:))
        let currentPort = audioSession.currentRoute.inputs.first
        let decision = VoiceAudioRoutePolicy.decide(
            availableInputs: candidates,
            currentInput: currentPort.map(Self.candidate(for:)),
            preference: preference
        )

        let preferredPort = decision.preferredInputID.flatMap { id in
            availablePorts.first(where: { $0.uid == id })
        }
        if audioSession.preferredInput?.uid != preferredPort?.uid {
            try audioSession.setPreferredInput(preferredPort)
        }

        let currentOutputKinds = audioSession.currentRoute.outputs.map(\.portType)
        if decision.forcesBuiltInSpeaker {
            if !currentOutputKinds.contains(.builtInSpeaker) {
                try audioSession.overrideOutputAudioPort(.speaker)
            }
        } else if !currentOutputKinds.contains(where: Self.isExternalVoiceOutput) {
            try audioSession.overrideOutputAudioPort(.none)
        }
        if decision.forcesBuiltInSpeaker,
           let builtInPort = preferredPort
            ?? audioSession.currentRoute.inputs.first(where: { $0.portType == .builtInMic }) {
            configureDirectionalBuiltInMic(builtInPort)
        }

        #if DEBUG
        let input = audioSession.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let output = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        print("[VoiceAudio] route input=\(input) output=\(output) speakerOverride=\(decision.forcesBuiltInSpeaker)")
        #endif
    }

    private func configureDirectionalBuiltInMic(_ input: AVAudioSessionPortDescription) {
        guard input.portType == .builtInMic,
              let dataSources = input.dataSources else { return }

        let candidates = dataSources.map { source in
            VoiceAudioDataSourceCandidate(
                id: String(describing: source.dataSourceID),
                isFrontFacing: source.orientation == .front,
                supportedPatterns: (source.supportedPolarPatterns ?? []).compactMap { pattern in
                    switch pattern {
                    case .cardioid: return .cardioid
                    case .subcardioid: return .subcardioid
                    default: return nil
                    }
                }
            )
        }
        guard let decision = VoiceAudioDataSourcePolicy.decide(
            availableDataSources: candidates
        ), let selected = dataSources.first(where: {
            String(describing: $0.dataSourceID) == decision.id
        }) else { return }

        do {
            switch decision.polarPattern {
            case .cardioid:
                try selected.setPreferredPolarPattern(.cardioid)
            case .subcardioid:
                try selected.setPreferredPolarPattern(.subcardioid)
            }
            try input.setPreferredDataSource(selected)
        } catch {
            print("[AudioSession] Directional microphone selection unavailable: \(error.localizedDescription)")
        }
    }

    private static func candidate(
        for port: AVAudioSessionPortDescription
    ) -> VoiceAudioInputCandidate {
        let kind: VoiceAudioInputKind
        switch port.portType {
        case .builtInMic:
            kind = .builtIn
        case .bluetoothHFP:
            kind = .bluetoothHFP
        case .headsetMic, .headphones:
            kind = .wired
        case .usbAudio:
            kind = .usb
        default:
            kind = .other
        }
        return VoiceAudioInputCandidate(id: port.uid, kind: kind)
    }

    private static func isExternalVoiceOutput(_ port: AVAudioSession.Port) -> Bool {
        switch port {
        case .bluetoothHFP, .headphones, .usbAudio, .lineOut, .carAudio:
            return true
        default:
            return false
        }
    }

    private func restoreTrackedAudioSession() {
        do {
            if let profile = claimRegistry.preferredProfile {
                try applyActiveProfile(profile)
            } else {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        } catch {
            print("[AudioSession] Failed to restore audio ownership: \(error.localizedDescription)")
        }
    }
}
