//
//  ContentView.swift
//  metaStreamMac
//
//  Created by Claude + humanwritten
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ReceiverViewModel()
    @State private var messageText = ""

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // Main content
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                        Text("metastream")
                            .font(.title)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)

                    Spacer()

                    videoDisplayArea

                    Spacer()

                    connectionControls

                    if viewModel.isConnected {
                        statsOverlay
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)

                // Message sidebar (when connected)
                if viewModel.isConnected {
                    messageSidebar
                }
            }
        }
    }

    @ViewBuilder
    private var videoDisplayArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(9/16, contentMode: .fit)
                .frame(maxHeight: 400)

            if viewModel.isConnected {
                if let frame = viewModel.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)

                        Text("Connected to \(viewModel.connectedDeviceName ?? "iPhone")")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Video streaming ready (Phase 4)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)

                    Text("Waiting for iPhone connection...")
                        .font(.headline)
                        .foregroundColor(.gray)

                    Text("Make sure both devices are on the same network")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
            }
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)

                Text(viewModel.connectionStatus)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }

            Spacer()

            Button(action: {
                if viewModel.isConnected {
                    viewModel.disconnect()
                } else {
                    viewModel.startDiscovery()
                }
            }) {
                HStack {
                    Image(systemName: viewModel.isConnected ? "xmark.circle" : "antenna.radiowaves.left.and.right")
                    Text(viewModel.isConnected ? "Disconnect" : "Start Discovery")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(viewModel.isConnected ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var statsOverlay: some View {
        HStack(spacing: 24) {
            StatItem(label: "Packets/s", value: String(format: "%.1f", viewModel.frameRate))
            StatItem(label: "Latency", value: "\(viewModel.latencyMs)ms")
            StatItem(label: "Received", value: formatBytes(viewModel.bytesReceived))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var messageSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "message.fill")
                Text("Messages")
                    .fontWeight(.medium)
                Spacer()
            }
            .padding()
            .background(Color.white.opacity(0.05))

            Divider()
                .background(Color.gray.opacity(0.3))

            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.receivedMessages.enumerated()), id: \.offset) { index, msg in
                            MessageBubble(message: msg, isFromMac: msg.deviceType == .mac)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.receivedMessages.count) { _, _ in
                    if let last = viewModel.receivedMessages.indices.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            // Message input
            HStack(spacing: 8) {
                TextField("Send a message...", text: $messageText)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty)
            }
            .padding()
        }
        .frame(width: 280)
        .background(Color.white.opacity(0.05))
        .foregroundColor(.white)
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        viewModel.sendMessage(messageText)

        // Add to local messages for display
        let localMessage = MetadataMessage(
            deviceName: Host.current().localizedName ?? "Mac",
            deviceType: .mac,
            message: messageText
        )
        viewModel.receivedMessages.append(localMessage)

        messageText = ""
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

struct MessageBubble: View {
    let message: MetadataMessage
    let isFromMac: Bool

    var body: some View {
        HStack {
            if isFromMac { Spacer() }

            VStack(alignment: isFromMac ? .trailing : .leading, spacing: 4) {
                if let text = message.message {
                    Text(text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isFromMac ? Color.blue : Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }

                Text("\(message.deviceName) • \(message.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            if !isFromMac { Spacer() }
        }
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
