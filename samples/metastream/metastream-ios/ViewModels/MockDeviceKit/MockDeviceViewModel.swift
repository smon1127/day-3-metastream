/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceViewModel.swift
//
// View model for individual mock devices used in development and testing of DAT SDK features.
// This controls mock device behaviors like power states, physical states (folded/unfolded),
// and media content (camera feeds and captured images).
//

#if DEBUG

import Foundation
import MWDATMockDevice

extension MockDeviceCardView {
  @MainActor
  final class ViewModel: ObservableObject {
    let device: MockDevice
    @Published var hasCameraFeed: Bool = false
    @Published var hasCapturedImage: Bool = false

    init(device: MockDevice, hasCameraFeed: Bool = false, hasCapturedImage: Bool = false) {
      self.device = device
      self.hasCameraFeed = hasCameraFeed
      self.hasCapturedImage = hasCapturedImage
      print("[MockDevice] 📱 Initialized mock device: \(device.deviceIdentifier)")
    }

    var id: String { device.deviceIdentifier }

    // Display name for the mock device in the UI
    var deviceName: String {
      if device is MockRaybanMeta {
        return "RayBan Meta Glasses"
      }
      return "Device"
    }

    func powerOn() {
      print("[MockDevice] ⚡ Power ON")
      device.powerOn()
    }

    func powerOff() {
      print("[MockDevice] 💤 Power OFF")
      device.powerOff()
    }

    func don() {
      print("[MockDevice] 👓 Don (wearing device)")
      device.don()
    }

    func doff() {
      print("[MockDevice] 👓 Doff (removing device)")
      device.doff()
    }

    func unfold() {
      if let rayBanDevice = device as? MockDisplaylessGlasses {
        print("[MockDevice] 📖 Unfolding glasses")
        rayBanDevice.unfold()
      }
    }

    func fold() {
      if let rayBanDevice = device as? MockDisplaylessGlasses {
        print("[MockDevice] 📕 Folding glasses")
        rayBanDevice.fold()
      }
    }

    // Load mock video content
    // Copy to documents directory to ensure persistent access
    //
    // NOTE: Mock video playback stutters and may have orientation issues. This appears to be
    // a limitation of the mock device SDK's video playback. Use a real Ray-Ban Meta device
    // for proper testing - mock devices are only useful for basic UI/flow testing.
    func selectVideo(from url: URL) {
      print("[MockDevice] 🎬 Selecting video from: \(url.lastPathComponent)")

      guard let cameraKit = (device as? MockDisplaylessGlasses)?.getCameraKit() else {
        print("[MockDevice] ❌ No camera kit available - device may not support camera")
        return
      }

      Task {
        do {
          // Copy video to documents directory for persistent access
          let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
          let destURL = documentsDir.appendingPathComponent("mock_video.mp4")

          // Remove existing file if present
          try? FileManager.default.removeItem(at: destURL)

          // Get file size for logging
          let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
          print("[MockDevice] 📁 Video file size: \(fileSize / 1024)KB")

          // Copy the video file
          try FileManager.default.copyItem(at: url, to: destURL)
          print("[MockDevice] ✅ Copied video to documents directory")

          // Set the camera feed with the copied file
          print("[MockDevice] 🔄 Setting camera feed...")
          await cameraKit.setCameraFeed(fileURL: destURL)
          await MainActor.run {
            hasCameraFeed = true
          }
          print("[MockDevice] ✅ Camera feed set - ready to stream!")
        } catch {
          print("[MockDevice] ❌ Failed to set video: \(error.localizedDescription)")
        }
      }
    }

    // Initialize device for streaming (power on, unfold, don)
    // Run on .default QoS to match SDK's internal BackgroundThread and avoid priority inversion
    func initializeForStreaming() {
      print("[MockDevice] 🔧 Initializing device for streaming...")

      // Capture device reference for background execution
      let deviceRef = device
      let isDisplaylessGlasses = device is MockDisplaylessGlasses

      DispatchQueue.global(qos: .default).async {
        print("[MockDevice] ⚡ Step 1: Power ON")
        deviceRef.powerOn()

        if isDisplaylessGlasses, let rayBanDevice = deviceRef as? MockDisplaylessGlasses {
          print("[MockDevice] 📖 Step 2: Unfolding glasses")
          rayBanDevice.unfold()
        }

        print("[MockDevice] 👓 Step 3: Don (wearing device)")
        deviceRef.don()

        print("[MockDevice] ✅ Device initialized and ready for streaming!")
      }
    }

    // Load mock image content
    func selectImage(from url: URL) {
      print("[MockDevice] 🖼️ Selecting image from: \(url.lastPathComponent)")

      guard let cameraKit = (device as? MockDisplaylessGlasses)?.getCameraKit() else {
        print("[MockDevice] ❌ No camera kit available")
        return
      }

      Task {
        print("[MockDevice] 🔄 Setting captured image...")
        await cameraKit.setCapturedImage(fileURL: url)
        await MainActor.run {
          hasCapturedImage = true
        }
        print("[MockDevice] ✅ Captured image set successfully")
      }
    }
  }
}

#endif
