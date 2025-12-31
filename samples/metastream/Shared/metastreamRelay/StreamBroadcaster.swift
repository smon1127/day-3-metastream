//
//  StreamBroadcaster.swift
//  metastreamRelay
//
//  Created by Claude + humanwritten
//  iOS side: Advertises service and broadcasts to connected Mac
//

import Foundation
import Network
import Combine
import CoreMedia

#if os(iOS)
import UIKit
#endif

@MainActor
class StreamBroadcaster: ObservableObject {
    // MARK: - Published Properties

    @Published var isAdvertising = false
    @Published var isConnected = false
    @Published var connectedPeerName: String?
    @Published var statusMessage = "Not broadcasting"
    @Published var receivedMessages: [MetadataMessage] = []
    @Published var isStreaming = false
    @Published var framesSent: UInt32 = 0

    // MARK: - Private Properties

    private var listener: NWListener?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var heartbeatTimeoutTimer: Timer?
    private var lastHeartbeatReceived: Date?
    private let heartbeatTimeout: TimeInterval = 5.0  // Match Mac's timeout

    private let serviceType = "_metastream._udp"
    private let serviceName: String

    // Video encoding
    private var encoder: LowLatencyEncoder?
    private var frameNumber: UInt32 = 0
    private var lastParameterSetsSentFrame: UInt32 = 0

    // MARK: - Initialization

    init() {
        #if os(iOS)
        self.serviceName = UIDevice.current.name
        #else
        self.serviceName = Host.current().localizedName ?? "Mac"
        #endif
    }

    // MARK: - Public Methods

    func startAdvertising() {
        guard !isAdvertising else { return }

        print("[Broadcaster] Starting advertising as '\(serviceName)' on \(serviceType)")

        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true

            listener = try NWListener(using: parameters)
            print("[Broadcaster] NWListener created")

            // Advertise as Bonjour service
            listener?.service = NWListener.Service(
                name: serviceName,
                type: serviceType
            )
            print("[Broadcaster] Service configured: \(serviceType)")

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("[Broadcaster] Listener state: \(state)")
                    switch state {
                    case .ready:
                        if let port = self.listener?.port {
                            print("[Broadcaster] ✅ Ready on port \(port)")
                        }
                        self.isAdvertising = true
                        self.statusMessage = "Broadcasting as '\(self.serviceName)'"
                    case .failed(let error):
                        print("[Broadcaster] ❌ Failed: \(error)")
                        self.isAdvertising = false
                        self.statusMessage = "Broadcast failed: \(error.localizedDescription)"
                    case .cancelled:
                        print("[Broadcaster] Cancelled")
                        self.isAdvertising = false
                        self.statusMessage = "Broadcast stopped"
                    case .waiting(let error):
                        print("[Broadcaster] ⏳ Waiting: \(error)")
                    case .setup:
                        print("[Broadcaster] Setting up...")
                    @unknown default:
                        print("[Broadcaster] Unknown state")
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }
                print("[Broadcaster] 📥 New connection from: \(newConnection.endpoint)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleNewConnection(newConnection)
                }
            }

            listener?.start(queue: .main)
            print("[Broadcaster] Listener started")

        } catch {
            print("[Broadcaster] ❌ Failed to create listener: \(error)")
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopAdvertising() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatTimeoutTimer?.invalidate()
        heartbeatTimeoutTimer = nil

        connection?.cancel()
        connection = nil

        listener?.cancel()
        listener = nil

        isAdvertising = false
        isConnected = false
        connectedPeerName = nil
        statusMessage = "Not broadcasting"
    }

    func sendMetadata(message: String) {
        guard isConnected else { return }

        let metadata = MetadataMessage(
            deviceName: serviceName,
            deviceType: .iPhone,
            message: message
        )

        guard let packet = metadata.toPacket() else { return }
        sendPacket(packet)
    }

    // MARK: - Video Streaming Methods

    /// Start video encoding and streaming
    /// - Parameters:
    ///   - width: Video width
    ///   - height: Video height
    func startVideoStream(width: Int32, height: Int32) {
        guard isConnected else {
            print("[Broadcaster] Cannot start video stream - not connected")
            return
        }

        guard encoder == nil else {
            print("[Broadcaster] Video stream already active")
            return
        }

        print("[Broadcaster] Starting video stream: \(width)x\(height)")

        encoder = LowLatencyEncoder(bitrate: 2_000_000, maxKeyframeInterval: 60, frameRate: 24.0)
        frameNumber = 0
        lastParameterSetsSentFrame = 0

        // Encoder callback runs on VideoToolbox callback thread
        encoder?.start(width: width, height: height) { [weak self] nalData, isKeyframe in
            Task { @MainActor [weak self] in
                self?.handleEncodedNAL(nalData, isKeyframe: isKeyframe)
            }
        }

        isStreaming = true
        statusMessage = "Streaming to \(connectedPeerName ?? "Mac")"
    }

    /// Stop video streaming
    func stopVideoStream() {
        encoder?.stop()
        encoder = nil
        isStreaming = false
        frameNumber = 0
        framesSent = 0
        if isConnected {
            statusMessage = "Connected to \(connectedPeerName ?? "Mac")"
        }
        print("[Broadcaster] Video stream stopped")
    }

    /// Encode and send a video frame
    /// - Parameter sampleBuffer: CMSampleBuffer from camera/SDK
    func sendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isConnected, let encoder = encoder else { return }
        encoder.encode(sampleBuffer)
    }

    /// Force a keyframe (e.g., when receiver requests it)
    func forceKeyframe() {
        encoder?.forceKeyframe()
    }

    private func handleEncodedNAL(_ nalData: Data, isKeyframe: Bool) {
        guard isConnected else { return }

        // Send parameter sets before first frame and periodically with keyframes
        if isKeyframe {
            if let sps = encoder?.sps, let pps = encoder?.pps {
                // Send parameter sets every 60 frames or on first keyframe
                if frameNumber == 0 || frameNumber - lastParameterSetsSentFrame >= 60 {
                    let paramPacket = ParameterSetsPacket(sps: sps, pps: pps)
                    sendPacket(paramPacket.toPacket(frameNumber: frameNumber))
                    lastParameterSetsSentFrame = frameNumber
                    print("[Broadcaster] Sent SPS/PPS with frame \(frameNumber)")
                }
            }
        }

        // Send video frame
        let videoPacket = VideoFramePacket(
            frameNumber: frameNumber,
            nalData: nalData,
            isKeyframe: isKeyframe
        )
        sendPacket(videoPacket.toPacket())

        frameNumber += 1
        framesSent = frameNumber

        // Log periodically
        if frameNumber % 100 == 0 {
            print("[Broadcaster] Sent \(frameNumber) frames")
        }
    }

    // MARK: - Private Methods

    private func handleNewConnection(_ newConnection: NWConnection) {
        // Only accept one connection at a time
        if connection != nil {
            print("[Broadcaster] Already have a connection, rejecting new one")
            newConnection.cancel()
            return
        }

        print("[Broadcaster] Accepting connection from: \(newConnection.endpoint)")
        connection = newConnection

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Broadcaster] Connection state: \(state)")
                switch state {
                case .ready:
                    print("[Broadcaster] ✅ Connection ready!")
                    self.isConnected = true
                    self.statusMessage = "Mac connected!"
                    self.startReceiving()
                    self.startHeartbeat()
                    self.startHeartbeatTimeout()
                case .failed(let error):
                    print("[Broadcaster] ❌ Connection failed: \(error)")
                    self.handleDisconnection(reason: error.localizedDescription)
                case .cancelled:
                    print("[Broadcaster] Connection cancelled")
                    self.handleDisconnection(reason: "Connection closed")
                case .preparing:
                    print("[Broadcaster] Connection preparing...")
                case .waiting(let error):
                    print("[Broadcaster] Connection waiting: \(error)")
                case .setup:
                    print("[Broadcaster] Connection setup...")
                @unknown default:
                    print("[Broadcaster] Connection unknown state")
                }
            }
        }

        connection?.start(queue: .main)
        print("[Broadcaster] Connection started")
    }

    private func handleDisconnection(reason: String) {
        // Stop video stream if active
        stopVideoStream()

        connection?.cancel()
        connection = nil
        isConnected = false
        connectedPeerName = nil
        statusMessage = "Disconnected: \(reason)"
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatTimeoutTimer?.invalidate()
        heartbeatTimeoutTimer = nil
        lastHeartbeatReceived = nil
    }

    private func startReceiving() {
        receiveNextPacket()
    }

    private func receiveNextPacket() {
        connection?.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data = content, let packet = Packet(data: data) {
                    self.handlePacket(packet)
                }

                if error == nil, self.isConnected {
                    self.receiveNextPacket()
                }
            }
        }
    }

    private func handlePacket(_ packet: Packet) {
        // Reset heartbeat timeout on any received packet
        resetHeartbeatTimeout()

        switch packet.type {
        case .handshake:
            if let handshake = HandshakePayload.from(packet: packet) {
                print("[Broadcaster] 🤝 Handshake from: \(handshake.deviceName)")
                connectedPeerName = handshake.deviceName
                statusMessage = "Connected to \(handshake.deviceName)"

                // Send acknowledgment
                let ack = HandshakePayload(deviceName: serviceName, deviceType: .iPhone)
                if let ackPacket = ack.toPacket() {
                    var ackData = ackPacket.toData()
                    // Change type to handshakeAck
                    ackData[4] = PacketType.handshakeAck.rawValue
                    sendRawData(ackData)
                    print("[Broadcaster] ✅ Sent handshake ack")
                }
            }

        case .metadata:
            if let metadata = MetadataMessage.from(packet: packet) {
                print("[Broadcaster] 💬 Message from \(metadata.deviceName): \(metadata.message ?? "")")
                receivedMessages.append(metadata)
                // Keep only last 50 messages
                if receivedMessages.count > 50 {
                    receivedMessages.removeFirst()
                }
            }

        case .heartbeat:
            // Respond to heartbeat (no logging to reduce spam)
            sendPacket(Packet(type: .heartbeat))

        default:
            print("[Broadcaster] Unknown packet type: \(packet.type)")
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPacket(Packet(type: .heartbeat))
            }
        }
    }

    private func startHeartbeatTimeout() {
        lastHeartbeatReceived = Date()
        heartbeatTimeoutTimer?.invalidate()
        heartbeatTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHeartbeatTimeout()
            }
        }
    }

    private func checkHeartbeatTimeout() {
        guard let lastReceived = lastHeartbeatReceived else { return }

        if Date().timeIntervalSince(lastReceived) > heartbeatTimeout {
            print("[Broadcaster] ⚠️ Heartbeat timeout - disconnecting")
            handleDisconnection(reason: "Connection timeout - no response from Mac")
        }
    }

    private func resetHeartbeatTimeout() {
        lastHeartbeatReceived = Date()
    }

    private func sendPacket(_ packet: Packet) {
        sendRawData(packet.toData())
    }

    private func sendRawData(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[Broadcaster] Send error: \(error)")
            }
        })
    }
}
