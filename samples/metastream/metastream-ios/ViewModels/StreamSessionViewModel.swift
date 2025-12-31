/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import AVFoundation
import Combine
import CoreMedia
import MWDATCamera
import MWDATCore
import Photos
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  // Timer properties
  @Published var activeTimeLimit: StreamTimeLimit = .noLimit
  @Published var remainingTime: TimeInterval = 0

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Mac relay properties (Phase 3)
  @Published var relayEnabled: Bool = false
  @Published var relayConnected: Bool = false
  @Published var relayStatus: String = "Not broadcasting"
  @Published var relayMessages: [MetadataMessage] = []
  let broadcaster = StreamBroadcaster()

  // Recording properties
  @Published var isRecording: Bool = false
  @Published var recordingDuration: TimeInterval = 0
  private var assetWriter: AVAssetWriter?
  private var assetWriterInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var recordingStartTime: CMTime?
  private var recordingURL: URL?
  private var recordingTimer: Timer?

  // Track last frame dimensions for relay reconnection
  private var lastFrameWidth: Int32 = 0
  private var lastFrameHeight: Int32 = 0
  private var videoFrameCount: Int = 0

  private var timerTask: Task<Void, Never>?
  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var relayObservers: [Any] = []

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    // Subscribe to session state changes using the DAT SDK listener pattern
    // State changes tell us when streaming starts, stops, or encounters issues
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // Each VideoFrame contains the raw camera data that we convert to UIImage
    // Use class-level counter to avoid concurrent mutation warnings
    let videoProcessingQueue = DispatchQueue(label: "com.metastream.videoProcessing", qos: .userInitiated)

    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      guard let self else { return }

      // Get sample buffer before any async work
      let sampleBuffer = videoFrame.sampleBuffer
      // Use nonisolated(unsafe) for CMSampleBuffer which is thread-safe for our usage
      nonisolated(unsafe) let safeSampleBuffer = sampleBuffer

      // Increment frame count atomically on main actor
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.videoFrameCount += 1
        let currentFrameCount = self.videoFrameCount

        // Log frame receipt periodically
        if currentFrameCount == 1 || currentFrameCount % 100 == 0 {
          print("[StreamSession] 📹 Received frame #\(currentFrameCount)")
        }

        // Track frame dimensions (lightweight)
        let frameWidth: Int32
        let frameHeight: Int32
        if let imageBuffer = CMSampleBufferGetImageBuffer(safeSampleBuffer) {
          frameWidth = Int32(CVPixelBufferGetWidth(imageBuffer))
          frameHeight = Int32(CVPixelBufferGetHeight(imageBuffer))
        } else {
          frameWidth = 0
          frameHeight = 0
        }

        // Update frame dimensions
        if frameWidth > 0 && frameHeight > 0 {
          self.lastFrameWidth = frameWidth
          self.lastFrameHeight = frameHeight
        }

        // Process image conversion on background queue to avoid main thread stutter
        videoProcessingQueue.async {
          // Convert to UIImage off main thread (CPU-intensive)
          let image = videoFrame.makeUIImage()

          // Update UI state on main thread (lightweight)
          Task { @MainActor [weak self] in
            guard let self else { return }

            // Update display
            if let image = image {
              self.currentVideoFrame = image
              if !self.hasReceivedFirstFrame {
                self.hasReceivedFirstFrame = true
                print("[StreamSession] ✅ First frame received and displayed")
              }
            }
          }
        }

        // Send to relay if connected (do this on main actor, separate from image conversion)
        if self.broadcaster.isConnected {
          // Start video stream on first frame if not already started
          if !self.broadcaster.isStreaming {
            if self.lastFrameWidth > 0 && self.lastFrameHeight > 0 {
              print("[StreamSession] 🚀 Starting video relay: \(self.lastFrameWidth)x\(self.lastFrameHeight)")
              self.broadcaster.startVideoStream(width: self.lastFrameWidth, height: self.lastFrameHeight)
            }
          }
          self.broadcaster.sendVideoFrame(safeSampleBuffer)
        } else if currentFrameCount == 1 {
          print("[StreamSession] ⚠️ Relay not connected - frames will only display locally")
        }

        // Write to recording if active
        if self.isRecording {
          self.writeFrameToRecording(safeSampleBuffer)
        }
      }
    }

    // Subscribe to streaming errors
    // Errors include device disconnection, streaming failures, etc.
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    // PhotoData contains the captured image in the requested format (JPEG/HEIC)
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }

    // Set up relay broadcaster observers
    setupRelayObservers()
  }

  private func setupRelayObservers() {
    // Observe broadcaster state changes
    relayObservers.append(
      broadcaster.$isConnected.sink { [weak self] connected in
        Task { @MainActor [weak self] in
          guard let self else { return }
          let wasConnected = self.relayConnected
          self.relayConnected = connected

          // Handle relay connecting while already streaming
          if connected && !wasConnected && self.streamingStatus == .streaming {
            // Relay just connected and we're already streaming - start video relay
            if self.lastFrameWidth > 0 && self.lastFrameHeight > 0 && !self.broadcaster.isStreaming {
              print("[StreamSession] Relay connected mid-stream, starting video relay")
              self.broadcaster.startVideoStream(width: self.lastFrameWidth, height: self.lastFrameHeight)
            }
          }

          // Handle relay disconnecting while streaming video
          if !connected && wasConnected && self.broadcaster.isStreaming {
            print("[StreamSession] Relay disconnected mid-stream, stopping video relay")
            self.broadcaster.stopVideoStream()
          }
        }
      }
    )

    relayObservers.append(
      broadcaster.$statusMessage.sink { [weak self] status in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.relayStatus = status
        }
      }
    )

    relayObservers.append(
      broadcaster.$receivedMessages.sink { [weak self] messages in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.relayMessages = messages
        }
      }
    )

    relayObservers.append(
      broadcaster.$isAdvertising.sink { [weak self] advertising in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.relayEnabled = advertising
        }
      }
    )
  }

  // MARK: - Relay Methods

  func toggleRelay() {
    if relayEnabled {
      broadcaster.stopAdvertising()
    } else {
      broadcaster.startAdvertising()
    }
  }

  func sendRelayMessage(_ text: String) {
    broadcaster.sendMetadata(message: text)
    // Add to local messages for display
    let localMessage = MetadataMessage(
      deviceName: UIDevice.current.name,
      deviceType: .iPhone,
      message: text
    )
    relayMessages.append(localMessage)
  }

  // MARK: - Recording Methods

  func startRecording() {
    guard !isRecording, lastFrameWidth > 0, lastFrameHeight > 0 else {
      print("[Recording] Cannot start - no frame dimensions yet")
      return
    }

    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let videoURL = documentsPath.appendingPathComponent("RBM_\(timestamp).mov")
    recordingURL = videoURL

    do {
      assetWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mov)

      // Use max quality settings - uncompressed or high bitrate H.264
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: lastFrameWidth,
        AVVideoHeightKey: lastFrameHeight,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 20_000_000,  // 20 Mbps for high quality
          AVVideoMaxKeyFrameIntervalKey: 1,  // All keyframes for max quality
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
      ]

      assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      assetWriterInput?.expectsMediaDataInRealTime = true

      let sourcePixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: lastFrameWidth,
        kCVPixelBufferHeightKey as String: lastFrameHeight
      ]

      pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: assetWriterInput!,
        sourcePixelBufferAttributes: sourcePixelBufferAttributes
      )

      if let input = assetWriterInput {
        assetWriter?.add(input)
      }

      assetWriter?.startWriting()
      recordingStartTime = nil
      isRecording = true
      recordingDuration = 0

      // Start duration timer
      recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        Task { @MainActor in
          self?.recordingDuration += 0.1
        }
      }

      print("[Recording] Started recording to \(videoURL.lastPathComponent)")
    } catch {
      print("[Recording] Failed to start: \(error)")
      showError("Failed to start recording: \(error.localizedDescription)")
    }
  }

  func stopRecording() {
    guard isRecording, let url = recordingURL else { return }

    recordingTimer?.invalidate()
    recordingTimer = nil
    isRecording = false

    assetWriterInput?.markAsFinished()
    assetWriter?.finishWriting {
      Task { @MainActor in
        // Save to Photos library
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          guard status == .authorized || status == .limited else {
            print("[Recording] Photo library access denied")
            return
          }

          PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
          } completionHandler: { success, error in
            Task { @MainActor in
              if success {
                print("[Recording] Saved to Photos library")
                // Clean up temp file
                try? FileManager.default.removeItem(at: url)
              } else if let error {
                print("[Recording] Failed to save: \(error)")
              }
            }
          }
        }
      }
    }

    assetWriter = nil
    assetWriterInput = nil
    pixelBufferAdaptor = nil
    recordingStartTime = nil
    recordingURL = nil

    print("[Recording] Stopped")
  }

  private func writeFrameToRecording(_ sampleBuffer: CMSampleBuffer) {
    guard isRecording,
          let writer = assetWriter,
          let input = assetWriterInput,
          let adaptor = pixelBufferAdaptor,
          input.isReadyForMoreMediaData,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Start session on first frame
    if recordingStartTime == nil {
      recordingStartTime = presentationTime
      writer.startSession(atSourceTime: presentationTime)
    }

    adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    // Reset to unlimited time when starting a new stream
    activeTimeLimit = .noLimit
    remainingTime = 0
    stopTimer()

    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    stopTimer()
    await streamSession.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func setTimeLimit(_ limit: StreamTimeLimit) {
    activeTimeLimit = limit
    remainingTime = limit.durationInSeconds ?? 0

    if limit.isTimeLimited {
      startTimer()
    } else {
      stopTimer()
    }
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startTimer() {
    stopTimer()
    timerTask = Task { @MainActor [weak self] in
      while let self, remainingTime > 0 {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        guard !Task.isCancelled else { break }
        remainingTime -= 1
      }
      if let self, !Task.isCancelled {
        await stopSession()
      }
    }
  }

  private func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      hasReceivedFirstFrame = false
      // Stop video relay when stream stops
      if broadcaster.isStreaming {
        print("[StreamSession] Stream stopped, stopping video relay")
        broadcaster.stopVideoStream()
      }
      // Reset frame dimensions and count
      lastFrameWidth = 0
      lastFrameHeight = 0
      videoFrameCount = 0
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
