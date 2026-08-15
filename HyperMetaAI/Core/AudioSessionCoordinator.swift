/*
 * Audio Session Coordinator
 * Serializes process-wide AVAudioSession ownership across realtime features.
 */

import AVFoundation
import Foundation

enum AudioSessionOwner: Hashable {
    case liveAI
    case liveTranslate
    case openClawASR
    case qwenVoice
    case textToSpeech
}

enum AudioSessionProfile: Hashable {
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

final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private let lock = NSLock()
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
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try audioSession.setPreferredSampleRate(24_000)
        case .translation(let usePhoneMic):
            let options: AVAudioSession.CategoryOptions = usePhoneMic
                ? [.defaultToSpeaker]
                : [.allowBluetoothHFP, .defaultToSpeaker]
            try audioSession.setCategory(.playAndRecord, mode: .default, options: options)
        case .playback:
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
        }

        try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
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
