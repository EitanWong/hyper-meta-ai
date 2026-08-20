import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class PhonePreviewSharpeningConfigurationTests: XCTestCase {
  func testIsDisabledWithoutTheLaunchArgument() {
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(arguments: ["HyperMetaAI"]),
      .disabled
    )
  }

  func testEnablesOnlyForAnExplicitTruthyLaunchArgument() {
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(
        arguments: ["HyperMetaAI", "-PhonePreviewSharpeningEnabled", "YES"]
      ),
      .enabled
    )
    XCTAssertEqual(
      PhonePreviewSharpeningConfiguration.from(
        arguments: ["HyperMetaAI", "-PhonePreviewSharpeningEnabled", "NO"]
      ),
      .disabled
    )
  }

  func testLowPowerModeReducesTheDisplayOnlyBudget() {
    let budget = PhonePreviewSharpeningBudget.apply(
      requested: .enabled,
      isLowPowerModeEnabled: true,
      thermalState: .nominal
    )

    XCTAssertTrue(budget.isEnabled)
    XCTAssertEqual(budget.maximumFramesPerSecond, 10)
    XCTAssertEqual(budget.maximumPixelDimension, 960)
    XCTAssertEqual(budget.sharpness, 0.18)
  }

  func testSeriousThermalStateReducesTheDisplayOnlyBudget() {
    let budget = PhonePreviewSharpeningBudget.apply(
      requested: .enabled,
      isLowPowerModeEnabled: false,
      thermalState: .serious
    )

    XCTAssertTrue(budget.isEnabled)
    XCTAssertEqual(budget.maximumFramesPerSecond, 10)
    XCTAssertEqual(budget.maximumPixelDimension, 960)
    XCTAssertEqual(budget.sharpness, 0.18)
  }

  func testCriticalThermalStateDisablesThePreviewFilter() {
    XCTAssertEqual(
      PhonePreviewSharpeningBudget.apply(
        requested: .enabled,
        isLowPowerModeEnabled: false,
        thermalState: .critical
      ),
      .disabled
    )
  }

  func testRuntimeBudgetCanDisableTheFilterWithoutTouchingTheSourceBuffer() {
    let source = makePixelBuffer(width: 8, height: 8)
    let renderer = PhonePreviewSharpeningRenderer(
      configuration: .enabled,
      runtimeBudget: { _ in .disabled }
    )

    guard case .ready(let preview) = renderer.prepare(source) else {
      return XCTFail("A disabled runtime budget should pass the source through")
    }

    XCTAssertTrue(CFEqual(source, preview))
    XCTAssertEqual(renderer.drainPerformanceSnapshot().inputFrames, 0)
  }

  func testCreatesAnIndependentDisplayBufferWithoutMutatingTheSource() {
    let source = makePixelBuffer(width: 8, height: 8)
    fillPixelBuffer(source, with: 0x7F)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    let preview: CVPixelBuffer
    switch renderer.prepare(source) {
    case .ready(let pixelBuffer):
      preview = pixelBuffer
    case .throttled:
      return XCTFail("The first preview frame should not be throttled")
    }

    XCTAssertEqual(CVPixelBufferGetPixelFormatType(preview), kCVPixelFormatType_32BGRA)
    XCTAssertFalse(CFEqual(source, preview))
    XCTAssertTrue(readPixelBufferBytes(source).allSatisfy { $0 == 0x7F })

    let metrics = renderer.drainPerformanceSnapshot()
    XCTAssertEqual(metrics.inputFrames, 1)
    XCTAssertEqual(metrics.renderedFrames, 1)
    XCTAssertEqual(metrics.renderFailures, 0)
  }

  func testBoundsSharpenedDisplayOutputToConfiguredPixelDimension() {
    let source = makePixelBuffer(width: 1_600, height: 900)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    let preview: CVPixelBuffer
    switch renderer.prepare(source) {
    case .ready(let pixelBuffer):
      preview = pixelBuffer
    case .throttled:
      return XCTFail("The first preview frame should not be throttled")
    }

    XCTAssertEqual(CVPixelBufferGetWidth(preview), 1_280)
    XCTAssertEqual(CVPixelBufferGetHeight(preview), 720)
    XCTAssertFalse(CFEqual(source, preview))
  }

  func testDropsFramesThatExceedThePreviewBudgetCadence() {
    let configuration = PhonePreviewSharpeningConfiguration(
      isEnabled: true,
      maximumFramesPerSecond: 1,
      maximumPixelDimension: 64,
      sharpness: 0.25
    )
    let renderer = PhonePreviewSharpeningRenderer(configuration: configuration)
    let source = makePixelBuffer(width: 8, height: 8)

    guard case .ready = renderer.prepare(source) else {
      return XCTFail("The first preview frame should not be throttled")
    }
    guard case .throttled = renderer.prepare(source) else {
      return XCTFail("The second immediate frame should be throttled")
    }

    let metrics = renderer.drainPerformanceSnapshot()
    XCTAssertEqual(metrics.inputFrames, 2)
    XCTAssertEqual(metrics.renderedFrames, 1)
    XCTAssertEqual(metrics.throttleDrops, 1)
  }

  func testSharpeningPerformanceForDATLowResolutionFrame() {
    let source = makePixelBuffer(width: 504, height: 504)
    fillPixelBuffer(source, with: 0x7F)
    let renderer = PhonePreviewSharpeningRenderer(configuration: .enabled)

    // Warm Core Image and the pixel-buffer pool before recording the steady
    // state. The result bundle retains the measurement for trend comparison.
    _ = renderer.prepare(source)
    renderer.reset()

    let options = XCTMeasureOptions()
    options.iterationCount = 5
    measure(metrics: [XCTClockMetric()], options: options) {
      renderer.reset()
      guard case .ready = renderer.prepare(source) else {
        return XCTFail("A reset renderer should accept its first frame")
      }
    }
  }

  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    return try! XCTUnwrap(pixelBuffer)
  }

  private func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer, with value: UInt8) {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return XCTFail("Expected writable pixel buffer memory")
    }
    _ = memset(baseAddress, Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
  }

  private func readPixelBufferBytes(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      XCTFail("Expected readable pixel buffer memory")
      return []
    }
    return Array(
      UnsafeBufferPointer(
        start: baseAddress.assumingMemoryBound(to: UInt8.self),
        count: CVPixelBufferGetDataSize(pixelBuffer)
      )
    )
  }
}
