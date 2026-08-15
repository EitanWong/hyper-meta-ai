/*
 * Metal Orb View
 * GPU-rendered light orb for the assistant's primary presence.
 */

import MetalKit
import SwiftUI
import UIKit

enum AssistantOrbState: UInt32, Equatable {
    case idle = 0
    case connecting = 1
    case listening = 2
    case thinking = 3
    case speaking = 4
    case working = 5
    case error = 6
}

struct MetalOrbView: View {
    let state: AssistantOrbState
    var intensity: Float = 0.65
    var audioLevel: Float = 0

    var body: some View {
        ZStack {
            // Restrained rings remain visible as a transparent fallback if Metal is unavailable.
            Circle()
                .stroke(fallbackGradient, lineWidth: 22)
                .blur(radius: 30)
                .scaleEffect(0.56 + CGFloat(intensity) * 0.012)
                .opacity(0.12 + Double(intensity) * 0.08)

            Circle()
                .stroke(fallbackGradient, lineWidth: 8)
                .blur(radius: 10)
                .scaleEffect(0.525 + CGFloat(audioLevel) * 0.018)
                .opacity(0.22 + Double(intensity) * 0.10)

            Circle()
                .fill(Color.white.opacity(0.018))
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                }
                .scaleEffect(0.515 + CGFloat(audioLevel) * 0.014)

            MetalOrbSurface(
                state: state,
                intensity: intensity,
                audioLevel: audioLevel
            )
        }
        .accessibilityHidden(true)
    }

    private var fallbackGradient: AngularGradient {
        AngularGradient(
            colors: [
                fallbackColors.primary,
                fallbackColors.accent,
                fallbackColors.primary,
            ],
            center: .center
        )
    }

    private var fallbackColors: (primary: Color, accent: Color) {
        switch state {
        case .listening:
            return (
                Color(red: 0.18, green: 0.88, blue: 0.82),
                Color(red: 0.18, green: 0.52, blue: 1.00)
            )
        case .thinking:
            return (
                Color(red: 0.28, green: 0.58, blue: 1.00),
                Color(red: 0.67, green: 0.38, blue: 0.96)
            )
        case .speaking:
            return (
                Color(red: 0.38, green: 0.64, blue: 1.00),
                Color(red: 0.96, green: 0.38, blue: 0.65)
            )
        case .working:
            return (
                Color(red: 0.12, green: 0.78, blue: 1.00),
                Color(red: 0.34, green: 0.90, blue: 0.72)
            )
        case .error:
            return (
                Color(red: 1.00, green: 0.28, blue: 0.34),
                Color(red: 1.00, green: 0.62, blue: 0.30)
            )
        case .connecting:
            return (
                Color(red: 0.18, green: 0.62, blue: 1.00),
                Color(red: 0.28, green: 0.88, blue: 0.84)
            )
        case .idle:
            return (
                Color(red: 0.20, green: 0.62, blue: 1.00),
                Color(red: 0.62, green: 0.38, blue: 0.96)
            )
        }
    }
}

private struct MetalOrbSurface: UIViewRepresentable {
    let state: AssistantOrbState
    let intensity: Float
    let audioLevel: Float

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = UIAccessibility.isReduceMotionEnabled ? 30 : 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.contentMode = .redraw

        context.coordinator.attach(to: view)
        context.coordinator.update(
            state: state,
            intensity: intensity,
            audioLevel: audioLevel
        )
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            state: state,
            intensity: intensity,
            audioLevel: audioLevel
        )
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    final class Coordinator {
        private var renderer: MetalOrbRenderer?

        func attach(to view: MTKView) {
            renderer = MetalOrbRenderer(view: view)
            view.delegate = renderer
            view.isHidden = renderer == nil
        }

        func update(state: AssistantOrbState, intensity: Float, audioLevel: Float) {
            renderer?.state = state
            renderer?.targetIntensity = min(max(intensity, 0), 1)
            renderer?.targetAudioLevel = min(max(audioLevel, 0), 1)
        }

        func detach(from view: MTKView) {
            view.delegate = nil
            renderer = nil
        }
    }
}

private final class MetalOrbRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var resolution = SIMD2<Float>(1, 1)
        var time: Float = 0
        var state: UInt32 = AssistantOrbState.idle.rawValue
        var intensity: Float = 0.65
        var audioLevel: Float = 0
        var reducedMotion: Float = 0
    }

    var state: AssistantOrbState = .idle
    var targetIntensity: Float = 0.65
    var targetAudioLevel: Float = 0

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime = CACurrentMediaTime()
    private var renderedIntensity: Float = 0.65
    private var renderedAudioLevel: Float = 0

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        let library = (try? device.makeDefaultLibrary(bundle: .main))
            ?? device.makeDefaultLibrary()
        guard let library,
              let vertexFunction = library.makeFunction(name: "assistantOrbVertex"),
              let fragmentFunction = library.makeFunction(name: "assistantOrbFragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Assistant Light Orb"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        renderedIntensity += (targetIntensity - renderedIntensity) * 0.08
        let audioSmoothing: Float = targetAudioLevel > renderedAudioLevel ? 0.34 : 0.10
        renderedAudioLevel += (targetAudioLevel - renderedAudioLevel) * audioSmoothing

        var uniforms = Uniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Float(CACurrentMediaTime() - startTime),
            state: state.rawValue,
            intensity: renderedIntensity,
            audioLevel: renderedAudioLevel,
            reducedMotion: UIAccessibility.isReduceMotionEnabled ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
