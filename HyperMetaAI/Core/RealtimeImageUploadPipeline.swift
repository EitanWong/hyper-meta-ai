import Foundation
import UIKit
import os.lock

enum RealtimeImageUploadOfferResult: Equatable, Sendable {
  case accepted
  case replacedPendingImage
  case inactive
  case staleGeneration

  var isAccepted: Bool {
    switch self {
    case .accepted, .replacedPendingImage:
      return true
    case .inactive, .staleGeneration:
      return false
    }
  }
}

/// Encodes at most one pending image. A new speech-triggered image replaces
/// work that has not started, so provider image uploads cannot accumulate.
final class RealtimeImageUploadPipeline: @unchecked Sendable {
  typealias EncodedImageHandler = (Data) -> Void

  private let queue: DispatchQueue
  private let compressionQuality: CGFloat
  private var lock = os_unfair_lock_s()
  private var activeGeneration: Int?
  private var nextSubmissionToken: UInt64 = 0
  private var pendingSubmissionToken: UInt64?
  private var pendingWorkItem: DispatchWorkItem?

  init(
    label: String,
    compressionQuality: CGFloat = 0.6
  ) {
    precondition((0...1).contains(compressionQuality))
    self.compressionQuality = compressionQuality
    queue = DispatchQueue(
      label: label,
      qos: .userInitiated,
      autoreleaseFrequency: .workItem
    )
  }

  deinit {
    stop()
  }

  func start(generation: Int) {
    os_unfair_lock_lock(&lock)
    pendingWorkItem?.cancel()
    pendingWorkItem = nil
    pendingSubmissionToken = nil
    activeGeneration = generation
    os_unfair_lock_unlock(&lock)
  }

  func stop() {
    os_unfair_lock_lock(&lock)
    activeGeneration = nil
    nextSubmissionToken &+= 1
    pendingSubmissionToken = nil
    pendingWorkItem?.cancel()
    pendingWorkItem = nil
    os_unfair_lock_unlock(&lock)
  }

  @discardableResult
  func submit(
    _ image: UIImage,
    generation: Int,
    handler: @escaping EncodedImageHandler
  ) -> RealtimeImageUploadOfferResult {
    os_unfair_lock_lock(&lock)
    guard let activeGeneration else {
      os_unfair_lock_unlock(&lock)
      return .inactive
    }
    guard activeGeneration == generation else {
      os_unfair_lock_unlock(&lock)
      return .staleGeneration
    }

    let replacesPendingImage = pendingSubmissionToken != nil
    pendingWorkItem?.cancel()
    nextSubmissionToken &+= 1
    let submissionToken = nextSubmissionToken
    pendingSubmissionToken = submissionToken

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isCurrent(submissionToken: submissionToken, generation: generation) else {
        return
      }

      guard let imageData = image.jpegData(compressionQuality: self.compressionQuality) else {
        self.finish(submissionToken: submissionToken)
        return
      }

      guard self.isCurrent(submissionToken: submissionToken, generation: generation) else {
        return
      }

      handler(imageData)
      self.finish(submissionToken: submissionToken)
    }
    pendingWorkItem = workItem
    os_unfair_lock_unlock(&lock)

    queue.async(execute: workItem)
    return replacesPendingImage ? .replacedPendingImage : .accepted
  }

  private func isCurrent(submissionToken: UInt64, generation: Int) -> Bool {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return activeGeneration == generation && pendingSubmissionToken == submissionToken
  }

  private func finish(submissionToken: UInt64) {
    os_unfair_lock_lock(&lock)
    if pendingSubmissionToken == submissionToken {
      pendingSubmissionToken = nil
      pendingWorkItem = nil
    }
    os_unfair_lock_unlock(&lock)
  }
}
