/*
 * Assistant Orb View
 * A monochrome, state-driven presence for the realtime assistant.
 */

import SwiftUI

enum AssistantOrbState: UInt32, Equatable {
    case idle = 0
    case connecting = 1
    case listening = 2
    case thinking = 3
    case speaking = 4
    case working = 5
    case error = 6
    case paused = 7
}

enum AssistantOrbMotionStyle: Equatable {
    case still
    case connecting
    case listening
    case thinking
    case speaking
    case working
    case error
    case paused
}

enum AssistantOrbRenderPolicy {
    static let audioStepCount = 6

    static func audioStep(_ level: Float) -> Int {
        let normalized = min(max(level, 0), 1)
        return Int((normalized * Float(audioStepCount)).rounded())
    }

    static func intensityStep(_ intensity: Float) -> Int {
        Int((min(max(intensity, 0), 1) * 10).rounded())
    }

    static func scale(state: AssistantOrbState, audioLevel: Float) -> CGFloat {
        let base: CGFloat
        let responseLimit: CGFloat
        switch state {
        case .listening:
            base = 0.70
            responseLimit = 0.032
        case .speaking:
            base = 0.72
            responseLimit = 0.040
        case .connecting, .thinking, .working:
            base = 0.68
            responseLimit = 0.008
        case .idle, .error:
            base = 0.66
            responseLimit = 0
        case .paused:
            base = 0.61
            responseLimit = 0
        }
        let response = CGFloat(audioStep(audioLevel)) / CGFloat(audioStepCount) * responseLimit
        return base + response
    }

    static func motionStyle(for state: AssistantOrbState) -> AssistantOrbMotionStyle {
        switch state {
        case .idle: return .still
        case .connecting: return .connecting
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .working: return .working
        case .error: return .error
        case .paused: return .paused
        }
    }

    static func coreOpacity(for state: AssistantOrbState) -> Double {
        switch state {
        case .idle: return 0.90
        case .connecting, .thinking, .working: return 0.94
        case .listening, .speaking: return 1
        case .paused: return 0.58
        case .error: return 0.86
        }
    }
}

struct AssistantOrbView: View, Equatable {
    let state: AssistantOrbState
    var intensity: Float = 0.65
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
            && AssistantOrbRenderPolicy.intensityStep(lhs.intensity)
                == AssistantOrbRenderPolicy.intensityStep(rhs.intensity)
            && AssistantOrbRenderPolicy.audioStep(lhs.audioLevel)
                == AssistantOrbRenderPolicy.audioStep(rhs.audioLevel)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.035 + normalizedIntensity * 0.025))
                .scaleEffect(0.98)

            AssistantOrbMotionLayer(
                style: AssistantOrbRenderPolicy.motionStyle(for: state),
                audioLevel: normalizedAudioLevel,
                reduceMotion: reduceMotion
            )
            .id(state)

            Circle()
                .fill(Color.white.opacity(AssistantOrbRenderPolicy.coreOpacity(for: state)))
                .scaleEffect(AssistantOrbRenderPolicy.scale(state: state, audioLevel: audioLevel))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: audioStep)
        .accessibilityHidden(true)
    }

    private var normalizedIntensity: Double {
        Double(AssistantOrbRenderPolicy.intensityStep(intensity)) / 10
    }

    private var normalizedAudioLevel: CGFloat {
        CGFloat(audioStep) / CGFloat(AssistantOrbRenderPolicy.audioStepCount)
    }

    private var audioStep: Int {
        AssistantOrbRenderPolicy.audioStep(audioLevel)
    }
}

private struct AssistantOrbMotionLayer: View {
    let style: AssistantOrbMotionStyle
    let audioLevel: CGFloat
    let reduceMotion: Bool

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            switch style {
            case .still:
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .scaleEffect(0.80)

            case .connecting:
                Circle()
                    .trim(from: 0.04, to: 0.31)
                    .stroke(
                        Color.white.opacity(0.82),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .scaleEffect(0.86)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(rotationAnimation(duration: 1.35), value: isAnimating)

            case .listening:
                Circle()
                    .stroke(Color.white.opacity(0.22 + Double(audioLevel) * 0.18), lineWidth: 1.5)
                    .scaleEffect(0.80 + audioLevel * 0.08)

                Circle()
                    .stroke(Color.white.opacity(isAnimating ? 0 : 0.30), lineWidth: 1)
                    .scaleEffect(isAnimating ? 1 : 0.80)
                    .animation(pulseAnimation(duration: 1.9), value: isAnimating)

            case .thinking:
                Circle()
                    .trim(from: 0.04, to: 0.26)
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .scaleEffect(0.84)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(rotationAnimation(duration: 2.2), value: isAnimating)

                Circle()
                    .trim(from: 0.52, to: 0.69)
                    .stroke(
                        Color.white.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                    .scaleEffect(0.94)
                    .rotationEffect(.degrees(isAnimating ? -360 : 0))
                    .animation(rotationAnimation(duration: 3.4), value: isAnimating)

            case .speaking:
                Circle()
                    .stroke(Color.white.opacity(isAnimating ? 0 : 0.34), lineWidth: 1.5)
                    .scaleEffect(isAnimating ? 1 : 0.76 + audioLevel * 0.05)
                    .animation(pulseAnimation(duration: 1.35), value: isAnimating)

                Circle()
                    .stroke(Color.white.opacity(isAnimating ? 0.02 : 0.20), lineWidth: 1)
                    .scaleEffect(isAnimating ? 0.94 : 0.72 + audioLevel * 0.04)
                    .animation(
                        pulseAnimation(duration: 1.35)?.delay(reduceMotion ? 0 : 0.42),
                        value: isAnimating
                    )

            case .working:
                Circle()
                    .stroke(
                        Color.white.opacity(0.58),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 9])
                    )
                    .scaleEffect(0.88)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(rotationAnimation(duration: 5.2), value: isAnimating)

            case .error:
                Circle()
                    .stroke(
                        Color.white.opacity(0.56),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 8])
                    )
                    .scaleEffect(0.84)

            case .paused:
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .scaleEffect(0.76)
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .scaleEffect(0.86)
            }
        }
        .onAppear {
            isAnimating = !reduceMotion
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            isAnimating = !shouldReduceMotion
        }
    }

    private func rotationAnimation(duration: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return .linear(duration: duration).repeatForever(autoreverses: false)
    }

    private func pulseAnimation(duration: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: duration).repeatForever(autoreverses: false)
    }
}
