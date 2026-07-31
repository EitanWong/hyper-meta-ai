/*
 * Provider audio contracts
 * Keeps session tokens and PCM properties explicit at the provider boundary.
 */

import Foundation

struct RealtimeProviderAudioProfile: Equatable, Sendable {
  let sessionInputFormat: String
  let sessionOutputFormat: String
  let inputSampleRate: Double
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
