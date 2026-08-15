/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import MWDATMockDevice
import XCTest

@testable import HyperMetaAI

@MainActor
private enum TestWearablesEnvironment {
  private static var hasConfiguredSDK = false

  static func configureIfNeeded() throws {
    guard !hasConfiguredSDK else { return }

    try Wearables.configure()
    hasConfiguredSDK = true
  }
}

@MainActor
final class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: (any MockGlasses)?
  private var cameraKit: (any MockCameraKit)?

  override func setUp() async throws {
    try await super.setUp()
    try TestWearablesEnvironment.configureIfNeeded()
    MockDeviceKit.shared.enable(
      config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true)
    )

    // Pair mock device and set up camera kit
    let pairedMockDevice = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // A mock device must be powered on and worn before DAT can start a stream.
    pairedMockDevice.powerOn()
    pairedMockDevice.don()
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.pairedDevices.forEach { mockDevice in
      MockDeviceKit.shared.unpairDevice(mockDevice)
    }
    MockDeviceKit.shared.disable()
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  private func makeStreamingViewModel() async -> StreamSessionViewModel? {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    let deviceBecameAvailable = await waitUntil { viewModel.hasActiveDevice }
    XCTAssertTrue(deviceBecameAvailable, "Mock glasses should become the active DAT device")
    return deviceBecameAvailable ? viewModel : nil
  }

  private func waitUntil(
    timeout: TimeInterval = 8,
    condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    return condition()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    guard let viewModel = await makeStreamingViewModel() else { return }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    let receivedFrame = await waitUntil {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }
    XCTAssertTrue(receivedFrame, viewModel.errorMessage)

    // Stop streaming
    await viewModel.stopSession()

    let stopped = await waitUntil { !viewModel.isStreaming && viewModel.streamingStatus == .stopped }
    XCTAssertTrue(stopped)
    await viewModel.shutdown()
  }

  func testRTMPLeaseStreamsMockRawFramesWithoutDirectPreviewRequirement() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }
    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    camera.setCameraFeed(fileURL: videoURL)
    guard let viewModel = await makeStreamingViewModel() else { return }

    let started = await viewModel.acquireStream(for: .rtmp)
    XCTAssertTrue(started, viewModel.errorMessage)

    let receivedFrame = await waitUntil {
      viewModel.cameraCaptureState == .streaming && viewModel.currentVideoFrame != nil
    }
    XCTAssertTrue(receivedFrame, viewModel.errorMessage)
    XCTAssertFalse(
      viewModel.usesDirectSampleBufferPreview,
      "RTMP's raw DAT path must not require the Live AI preview surface"
    )

    await viewModel.releaseStream(for: .rtmp)
    let stopped = await waitUntil { viewModel.cameraCaptureState == .idle }
    XCTAssertTrue(stopped)
    await viewModel.shutdown()
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    guard let imageURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "png") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    guard let viewModel = await makeStreamingViewModel() else { return }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    let receivedFrame = await waitUntil {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }
    XCTAssertTrue(receivedFrame, viewModel.errorMessage)

    // Capture photo while streaming
    viewModel.capturePhoto()
    let capturedPhoto = await waitUntil {
      viewModel.capturedPhoto != nil && viewModel.showPhotoPreview
    }
    XCTAssertTrue(capturedPhoto, viewModel.errorMessage)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    let stopped = await waitUntil { !viewModel.isStreaming && viewModel.streamingStatus == .stopped }
    XCTAssertTrue(stopped)
    await viewModel.shutdown()
  }

  func testCameraPermissionDenialDoesNotCreateASession() async throws {
    MockDeviceKit.shared.permissions.set(.camera, .denied)
    MockDeviceKit.shared.permissions.setRequestResult(.camera, result: .denied)

    guard let viewModel = await makeStreamingViewModel() else { return }
    await viewModel.handleStartStreaming()

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertEqual(viewModel.sessionState, .failed("Camera permission denied."))
    XCTAssertEqual(viewModel.errorMessage, "Camera permission denied.")
    await viewModel.shutdown()
  }

  func testOnDeviceAvailableFiresWhenGlassesConnect() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    let expectation = expectation(description: "onDeviceAvailable fired")
    var didFire = false
    viewModel.onDeviceAvailable = {
      guard !didFire else { return }
      didFire = true
      expectation.fulfill()
    }

    let becameAvailable = await waitUntil { viewModel.hasActiveDevice }
    XCTAssertTrue(becameAvailable)
    await fulfillment(of: [expectation], timeout: 5)
    await viewModel.shutdown()
  }

  func testCaptouchPauseWaitsForTheDeviceToResume() async throws {
    guard let camera = cameraKit, let mockDevice else {
      XCTFail("Mock device and camera should be available")
      return
    }
    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    camera.setCameraFeed(fileURL: videoURL)
    guard let viewModel = await makeStreamingViewModel() else { return }
    await viewModel.handleStartStreaming()

    let streamStarted = await waitUntil { viewModel.isStreaming }
    XCTAssertTrue(streamStarted, viewModel.errorMessage)

    mockDevice.services.captouch.tap()
    let paused = await waitUntil { viewModel.sessionState == .paused }
    XCTAssertTrue(paused)

    mockDevice.services.captouch.tap()
    let resumed = await waitUntil { viewModel.isStreaming }
    XCTAssertTrue(resumed, viewModel.errorMessage)
    await viewModel.stopSession()
    await viewModel.shutdown()
  }

  func testRapidStartThenStopDoesNotLeaveAStreamingSession() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }
    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    camera.setCameraFeed(fileURL: videoURL)
    guard let viewModel = await makeStreamingViewModel() else { return }

    let startTask = Task { @MainActor in
      await viewModel.handleStartStreaming()
    }
    // Let the request reach the first suspension point, then cancel its lease.
    try? await Task.sleep(nanoseconds: 20_000_000)
    await viewModel.stopSession()
    await startTask.value

    let stopped = await waitUntil(timeout: 3) {
      !viewModel.isStreaming &&
      viewModel.streamingStatus == .stopped &&
      viewModel.currentVideoFrame == nil
    }
    XCTAssertTrue(stopped, "A cancelled start must not revive the camera")
    await viewModel.shutdown()
  }

  func testRepeatedAcquireAndReleaseIsIdempotent() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }
    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    camera.setCameraFeed(fileURL: videoURL)
    guard let viewModel = await makeStreamingViewModel() else { return }

    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask { @MainActor in
          await viewModel.acquireStream(for: .cameraPreview)
        }
      }

      for await started in group {
        XCTAssertTrue(started, viewModel.errorMessage)
      }
    }

    let streaming = await waitUntil { viewModel.cameraCaptureState == .streaming }
    XCTAssertTrue(streaming, viewModel.errorMessage)

    // One owner has one lease even when acquisition was requested repeatedly.
    for _ in 0..<8 {
      await viewModel.releaseStream(for: .cameraPreview)
    }

    XCTAssertEqual(
      viewModel.cameraCaptureState,
      .idle,
      "The final release must wait for the DAT session to stop before returning"
    )
    let stopped = await waitUntil { viewModel.cameraCaptureState == .idle }
    XCTAssertTrue(stopped)
    XCTAssertNil(viewModel.currentVideoFrame)
    await viewModel.shutdown()
  }

  func testPoweringOffGlassesClearsFrameAndMarksCameraUnavailable() async throws {
    guard let camera = cameraKit, let mockDevice else {
      XCTFail("Mock device and camera should be available")
      return
    }
    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    camera.setCameraFeed(fileURL: videoURL)
    guard let viewModel = await makeStreamingViewModel() else { return }
    await viewModel.handleStartStreaming()

    let receivedFrame = await waitUntil { viewModel.isStreaming && viewModel.currentVideoFrame != nil }
    XCTAssertTrue(receivedFrame, viewModel.errorMessage)

    mockDevice.powerOff()

    let unavailable = await waitUntil(timeout: 5) {
      viewModel.cameraCaptureState == .unavailable &&
      !viewModel.isStreaming &&
      viewModel.currentVideoFrame == nil &&
      !viewModel.hasReceivedFirstFrame
    }
    XCTAssertTrue(unavailable, "Powering off must invalidate every camera UI signal")
    await viewModel.shutdown()
  }
}
