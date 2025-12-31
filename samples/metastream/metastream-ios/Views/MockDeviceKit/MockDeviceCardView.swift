/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceCardView.swift
//
// UI component for managing individual mock Meta wearable devices during development.
// This card provides controls for simulating device states (power, wearing, folding)
// and loading mock media content for testing DAT SDK streaming and photo capture features.
// Useful for testing without requiring physical Meta hardware.
//

#if DEBUG

import SwiftUI

struct MockDeviceCardView: View {
  @ObservedObject var viewModel: ViewModel
  let onUnpairDevice: () -> Void
  let onStartStreaming: (() -> Void)?
  @State private var showingVideoPicker = false
  @State private var showingImagePicker = false

  init(viewModel: ViewModel, onUnpairDevice: @escaping () -> Void, onStartStreaming: (() -> Void)? = nil) {
    self.viewModel = viewModel
    self.onUnpairDevice = onUnpairDevice
    self.onStartStreaming = onStartStreaming
  }

  var body: some View {
    CardView {
      VStack(spacing: 8) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.deviceName)
              .font(.headline)
              .foregroundColor(.primary)
              .lineLimit(1)
            Text(viewModel.id)
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          MockDeviceKitButton("Unpair", style: .destructive, expandsHorizontally: false) {
            onUnpairDevice()
          }
        }

        Divider()

        VStack(spacing: 8) {
          HStack(spacing: 8) {
            MockDeviceKitButton("Power On") {
              viewModel.powerOn()
            }

            MockDeviceKitButton("Power Off") {
              viewModel.powerOff()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("Don") {
              viewModel.don()
            }

            MockDeviceKitButton("Doff") {
              viewModel.doff()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("Unfold") {
              viewModel.unfold()
            }

            MockDeviceKitButton("Fold") {
              viewModel.fold()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("Select video") {
              showingVideoPicker = true
            }
            .sheet(isPresented: $showingVideoPicker) {
              MediaPickerView(mode: .video) { url, _ in
                viewModel.selectVideo(from: url)
              }
            }

            StatusText(
              isActive: viewModel.hasCameraFeed,
              activeText: "Has camera feed",
              inactiveText: "No camera feed"
            )

          }

          HStack(spacing: 8) {
            MockDeviceKitButton("Select image") {
              showingImagePicker = true
            }
            .sheet(isPresented: $showingImagePicker) {
              MediaPickerView(mode: .image) { url, _ in
                viewModel.selectImage(from: url)
              }
            }

            StatusText(
              isActive: viewModel.hasCapturedImage,
              activeText: "Has captured image",
              inactiveText: "No captured image"
            )
          }

          // Show Start Streaming button when camera feed is ready
          if viewModel.hasCameraFeed, let onStartStreaming = onStartStreaming {
            Divider()
              .padding(.vertical, 4)

            MockDeviceKitButton("🚀 Start Streaming", style: .primary) {
              print("[MockDevice] ▶️ Start Streaming tapped")
              // Initialize device (power on, unfold, don) before starting stream
              viewModel.initializeForStreaming()
              // Small delay to let device state settle before streaming starts
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onStartStreaming()
              }
            }
          }
        }
      }
      .padding()
    }
  }
}

// Replace this with PhotosPicker once we're on iOS 16 or newer

#endif
