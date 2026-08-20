import AVFoundation
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import XCTest

@testable import HyperMetaAI

final class RealtimeImageUploadPipelineTests: XCTestCase {
  func testEncodesImageOffTheMainThread() throws {
    let pipeline = RealtimeImageUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.image-upload"
    )
    let image = try makeTestImage()
    let encoded = expectation(description: "image is encoded")

    pipeline.start(generation: 7)
    let result = pipeline.submit(image, generation: 7) { imageData in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertFalse(imageData.isEmpty)
      encoded.fulfill()
    }

    XCTAssertEqual(result, .accepted)
    wait(for: [encoded], timeout: 2)
    pipeline.stop()
  }

  func testRejectsStaleGenerationAndSubmissionsAfterStop() throws {
    let pipeline = RealtimeImageUploadPipeline(
      label: "com.lunflux.hyper-meta-ai.tests.image-upload-generation"
    )
    let image = try makeTestImage()
    pipeline.start(generation: 11)

    XCTAssertEqual(
      pipeline.submit(image, generation: 10) { _ in },
      .staleGeneration
    )

    pipeline.stop()

    XCTAssertEqual(
      pipeline.submit(image, generation: 11) { _ in },
      .inactive
    )
  }

  private func makeTestImage() throws -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    return renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
  }
}
