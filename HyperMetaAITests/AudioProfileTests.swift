import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class RealtimeProviderAudioProfileTests: XCTestCase {
  func testQwenProfileUsesCanonicalPCMAndExplicitSampleRates() {
    let profile = RealtimeProviderAudioProfiles.qwen

    XCTAssertEqual(profile.sessionInputFormat, "pcm")
    XCTAssertEqual(profile.sessionOutputFormat, "pcm")
    XCTAssertEqual(profile.inputSampleRate, 16_000)
    XCTAssertEqual(profile.outputFormat, .realtimePCM16Mono24kHz)
  }

  func testQwenProfileBoundsUploadTailLatency() {
    let profile = RealtimeProviderAudioProfiles.qwen

    XCTAssertEqual(profile.uploadSendTimeout, 0.25)
    XCTAssertEqual(profile.maximumQueuedInputAge, 0.12)
    XCTAssertEqual(profile.criticalControlSendTimeout, 0.15)
  }

  func testOmniSessionConfigurationUsesTheQwenPCMContract() throws {
    let event = OmniRealtimeService.makeSessionConfiguration(
      eventID: "test-event",
      voice: "Tina",
      instructions: "test instructions"
    )
    let session = try XCTUnwrap(event["session"] as? [String: Any])

    XCTAssertEqual(event["event_id"] as? String, "test-event")
    XCTAssertEqual(event["type"] as? String, OmniClientEvent.sessionUpdate.rawValue)
    XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
    XCTAssertEqual(session["output_audio_format"] as? String, "pcm")
    XCTAssertEqual(session["modalities"] as? [String], ["text", "audio"])
  }
}

final class TTSOutputLevelTests: XCTestCase {
  func testMixerRMSIsNormalizedForOrbFeedback() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)
    )
    buffer.frameLength = 128
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<128 {
      samples[index] = 0.0625
    }

    XCTAssertEqual(TTSService.normalizedAudioLevel(buffer), 0.5, accuracy: 0.01)
  }
}

final class AudioSessionProfileTests: XCTestCase {
  func testRealtimeProfilesReserveTheExclusiveInputPath() {
    XCTAssertTrue(AudioSessionProfile.voiceChat.requiresExclusiveInput)
    XCTAssertTrue(AudioSessionProfile.translation(usePhoneMic: true).requiresExclusiveInput)
    XCTAssertFalse(AudioSessionProfile.playback.requiresExclusiveInput)
  }

  func testDuplicateLiveAIClaimDoesNotReconfigureTheAudioRoute() throws {
    var registry = AudioSessionClaimRegistry()

    XCTAssertEqual(
      try registry.activate(.liveAI, profile: .voiceChat),
      .apply(.voiceChat)
    )
    XCTAssertEqual(
      try registry.activate(.liveAI, profile: .voiceChat),
      .none
    )
  }

  func testDuplicateReleaseDoesNotDeactivateTheAudioRouteTwice() throws {
    var registry = AudioSessionClaimRegistry()
    _ = try registry.activate(.liveAI, profile: .voiceChat)

    XCTAssertEqual(registry.deactivate(.liveAI), .deactivate)
    XCTAssertEqual(registry.deactivate(.liveAI), .none)
  }

  func testLowerPriorityPlaybackClaimDoesNotReconfigureVoiceChat() throws {
    var registry = AudioSessionClaimRegistry()
    _ = try registry.activate(.liveAI, profile: .voiceChat)

    XCTAssertEqual(
      try registry.activate(.textToSpeech, profile: .playback),
      .none
    )
    XCTAssertEqual(registry.deactivate(.textToSpeech), .none)
    XCTAssertEqual(registry.deactivate(.liveAI), .deactivate)
  }
}
