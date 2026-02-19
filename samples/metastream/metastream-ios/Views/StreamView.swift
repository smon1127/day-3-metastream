/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var showRelaySheet = false
  @State private var relayMessageText = ""

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Status indicators (top)
      VStack(spacing: 6) {
        if viewModel.relayEnabled {
          HStack(spacing: 8) {
            Circle()
              .fill(viewModel.relayConnected ? Color.green : Color.orange)
              .frame(width: 8, height: 8)
            Text(viewModel.relayConnected ? "Mac Connected" : "Waiting for Mac...")
              .font(.system(size: 13))
              .foregroundColor(.white)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.black.opacity(0.6))
          .cornerRadius(16)
        }
        if viewModel.ndiEnabled {
          HStack(spacing: 8) {
            Circle()
              .fill(Color.green)
              .frame(width: 8, height: 8)
            Text("NDI Live")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(.white)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.red.opacity(0.8))
          .cornerRadius(16)
        }
        Spacer()
      }
      .padding(.top, 50)

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, showRelaySheet: $showRelaySheet)
      }
      .padding(.all, 24)

      // Timer display area with fixed height
      VStack {
        Spacer()
        if viewModel.activeTimeLimit.isTimeLimited && viewModel.remainingTime > 0 {
          Text("Streaming ending in \(viewModel.remainingTime.formattedCountdown)")
            .font(.system(size: 15))
            .foregroundColor(.white)
        }
      }
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    // Relay messages sheet
    .sheet(isPresented: $showRelaySheet) {
      RelayMessagesSheet(
        viewModel: viewModel,
        messageText: $relayMessageText,
        isPresented: $showRelaySheet
      )
    }
  }
}

// Relay messages sheet view
struct RelayMessagesSheet: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @Binding var messageText: String
  @Binding var isPresented: Bool

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Status banner
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Circle()
              .fill(viewModel.relayConnected ? Color.green : Color.orange)
              .frame(width: 10, height: 10)
            Text(viewModel.relayStatus)
              .font(.system(size: 14))
            Spacer()
            Toggle("", isOn: Binding(
              get: { viewModel.relayEnabled },
              set: { _ in viewModel.toggleRelay() }
            ))
            .labelsHidden()
          }
          .padding()

          Divider()

          HStack(spacing: 8) {
            Circle()
              .fill(viewModel.ndiEnabled ? Color.green : Color.gray)
              .frame(width: 10, height: 10)
            Text("Broadcast via NDI")
              .font(.system(size: 14))
            Spacer()
            Toggle("", isOn: Binding(
              get: { viewModel.ndiEnabled },
              set: { _ in viewModel.toggleNDI() }
            ))
            .labelsHidden()
          }
          .padding()

          if viewModel.ndiEnabled {
            HStack {
              Text(viewModel.ndiStatus)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
              Spacer()
              Text(String(format: "%.1f fps", viewModel.ndiBroadcaster.currentFPS))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
          }
        }
        .background(Color(.systemGray6))

        // Messages list
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(Array(viewModel.relayMessages.enumerated()), id: \.offset) { index, msg in
                RelayMessageBubble(message: msg, isFromiPhone: msg.deviceType == .iPhone)
                  .id(index)
              }
            }
            .padding()
          }
          .onChange(of: viewModel.relayMessages.count) { _, _ in
            if let last = viewModel.relayMessages.indices.last {
              withAnimation {
                proxy.scrollTo(last, anchor: .bottom)
              }
            }
          }
        }

        Divider()

        // Message input
        HStack(spacing: 8) {
          TextField("Send a message...", text: $messageText)
            .textFieldStyle(.roundedBorder)
            .disabled(!viewModel.relayConnected)
            .onSubmit {
              sendMessage()
            }

          Button(action: sendMessage) {
            Image(systemName: "paperplane.fill")
              .foregroundColor(viewModel.relayConnected ? .blue : .gray)
          }
          .disabled(messageText.isEmpty || !viewModel.relayConnected)
        }
        .padding()
      }
      .navigationTitle("Mac Relay")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") {
            isPresented = false
          }
        }
      }
    }
  }

  private func sendMessage() {
    guard !messageText.isEmpty, viewModel.relayConnected else { return }
    viewModel.sendRelayMessage(messageText)
    messageText = ""
  }
}

struct RelayMessageBubble: View {
  let message: MetadataMessage
  let isFromiPhone: Bool

  var body: some View {
    HStack {
      if isFromiPhone { Spacer() }

      VStack(alignment: isFromiPhone ? .trailing : .leading, spacing: 4) {
        if let text = message.message {
          Text(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isFromiPhone ? Color.blue : Color(.systemGray5))
            .foregroundColor(isFromiPhone ? .white : .primary)
            .cornerRadius(12)
        }

        Text("\(message.deviceName) • \(message.timestamp.formatted(date: .omitted, time: .shortened))")
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      if !isFromiPhone { Spacer() }
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @Binding var showRelaySheet: Bool

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Timer button
      CircleButton(
        icon: "timer",
        text: viewModel.activeTimeLimit != .noLimit ? viewModel.activeTimeLimit.displayText : nil
      ) {
        let nextTimeLimit = viewModel.activeTimeLimit.next
        viewModel.setTimeLimit(nextTimeLimit)
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }

      // Recording button
      RecordingButton(
        isRecording: viewModel.isRecording,
        duration: viewModel.recordingDuration
      ) {
        if viewModel.isRecording {
          viewModel.stopRecording()
        } else {
          viewModel.startRecording()
        }
      }

      // Mac relay button
      RelayCircleButton(
        isEnabled: viewModel.relayEnabled,
        isConnected: viewModel.relayConnected
      ) {
        showRelaySheet = true
      }
    }
  }
}

// Custom relay button with status indicator
struct RelayCircleButton: View {
  let isEnabled: Bool
  let isConnected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 16))

        // Status dot
        if isEnabled {
          Circle()
            .fill(isConnected ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .offset(x: 12, y: -12)
        }
      }
    }
    .foregroundColor(isEnabled ? .blue : .black)
    .frame(width: 56, height: 56)
    .background(.white)
    .clipShape(Circle())
  }
}

// Recording button with duration display
struct RecordingButton: View {
  let isRecording: Bool
  let duration: TimeInterval
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 2) {
        ZStack {
          if isRecording {
            // Red recording dot
            Circle()
              .fill(Color.red)
              .frame(width: 16, height: 16)
          } else {
            // Record icon
            Image(systemName: "record.circle")
              .font(.system(size: 20))
          }
        }
        if isRecording {
          Text(formatDuration(duration))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.red)
        }
      }
    }
    .foregroundColor(isRecording ? .red : .black)
    .frame(width: 56, height: 56)
    .background(isRecording ? Color.red.opacity(0.15) : .white)
    .clipShape(Circle())
    .animation(.easeInOut(duration: 0.2), value: isRecording)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
