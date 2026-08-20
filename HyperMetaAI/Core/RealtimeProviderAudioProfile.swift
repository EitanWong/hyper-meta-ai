/*
 * Provider audio contracts
 * Keeps session tokens and PCM properties explicit at the provider boundary.
 */

import Foundation

struct RealtimeProviderAudioProfile: Equatable, Sendable {
  let sessionInputFormat: String
  let sessionOutputFormat: String
  let inputSampleRate: Double
  let uploadSendTimeout: TimeInterval
  let maximumQueuedInputAge: TimeInterval
  let criticalControlSendTimeout: TimeInterval
  let outputFormat: RealtimePCMOutputFormat
  let maximumJitterMilliseconds: Double
  let maximumBufferedResponseMilliseconds: Double
  let maximumBufferedResponseChunkCount: Int
}

enum RealtimeProviderAudioProfiles {
  /// Qwen's `pcm` token represents signed 16-bit PCM. Input is 16 kHz mono;
  /// output is 24 kHz mono, as defined by the Realtime WebSocket protocol.
  static let qwen = RealtimeProviderAudioProfile(
    sessionInputFormat: "pcm",
    sessionOutputFormat: "pcm",
    inputSampleRate: 16_000,
    // A WebSocket send completion is a local transport handoff. Crossing this
    // deadline indicates a wedged path rather than useful conversational audio.
    uploadSendTimeout: 0.25,
    // Keep at most the most recent few microphone frames after transient stalls.
    maximumQueuedInputAge: 0.12,
    // Interrupt is locally applied first, but its provider cancel must either
    // reach the transport quickly or force a clean reconnect.
    criticalControlSendTimeout: 0.15,
    outputFormat: .realtimePCM16Mono24kHz,
    // Qwen's WebSocket response packets observed on device are approximately
    // 320 ms. Keep room for one packet plus a bounded scheduling margin.
    maximumJitterMilliseconds: 400,
    // Qwen can deliver synthesized audio significantly faster than real-time.
    // This is a bounded response spool, distinct from the startup jitter
    // window, sized from the 50.24-second device capture plus headroom.
    maximumBufferedResponseMilliseconds: 60_000,
    maximumBufferedResponseChunkCount: 256
  )
}

enum SpeechRecognitionTokenization: Sendable {
  case characters
  case words
}

struct SpeechRecognitionSample: Equatable, Sendable {
  let reference: String
  let hypothesis: String
}

struct SpeechRecognitionAccuracyReport: Equatable, Sendable {
  let errorCount: Int
  let referenceUnitCount: Int

  var errorRate: Double {
    guard referenceUnitCount > 0 else { return errorCount == 0 ? 0 : 1 }
    return Double(errorCount) / Double(referenceUnitCount)
  }

  var accuracy: Double {
    max(0, 1 - errorRate)
  }

  func meets(minimumAccuracy: Double) -> Bool {
    referenceUnitCount > 0 && accuracy >= minimumAccuracy
  }
}

enum SpeechRecognitionAccuracyEvaluator {
  /// Chinese ASR is gated at CER <= 8%; space-delimited languages use WER <= 10%.
  static let minimumCharacterAccuracy = 0.92
  static let minimumWordAccuracy = 0.90

  static func evaluate(
    _ samples: [SpeechRecognitionSample],
    tokenization: SpeechRecognitionTokenization
  ) -> SpeechRecognitionAccuracyReport {
    var totalErrors = 0
    var totalReferenceUnits = 0
    for sample in samples {
      let reference = units(sample.reference, tokenization: tokenization)
      let hypothesis = units(sample.hypothesis, tokenization: tokenization)
      totalErrors += editDistance(reference, hypothesis)
      totalReferenceUnits += reference.count
    }
    return SpeechRecognitionAccuracyReport(
      errorCount: totalErrors,
      referenceUnitCount: totalReferenceUnits
    )
  }

  private static func units(
    _ text: String,
    tokenization: SpeechRecognitionTokenization
  ) -> [String] {
    switch tokenization {
    case .characters:
      return text.lowercased().unicodeScalars.compactMap { scalar in
        CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : nil
      }
    case .words:
      return text.lowercased().split { character in
        !character.isLetter && !character.isNumber
      }.map(String.init)
    }
  }

  private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
    guard !lhs.isEmpty else { return rhs.count }
    guard !rhs.isEmpty else { return lhs.count }

    var previous = Array(0...rhs.count)
    for (leftIndex, left) in lhs.enumerated() {
      var current = Array(repeating: 0, count: rhs.count + 1)
      current[0] = leftIndex + 1
      for (rightIndex, right) in rhs.enumerated() {
        let substitution = previous[rightIndex] + (left == right ? 0 : 1)
        let insertion = current[rightIndex] + 1
        let deletion = previous[rightIndex + 1] + 1
        current[rightIndex + 1] = min(substitution, insertion, deletion)
      }
      previous = current
    }
    return previous[rhs.count]
  }
}
