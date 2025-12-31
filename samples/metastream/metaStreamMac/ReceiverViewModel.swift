//
//  ReceiverViewModel.swift
//  metaStreamMac
//
//  Created by Claude + humanwritten
//

import SwiftUI
import Combine
import Network
import CoreVideo

@MainActor
class ReceiverViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var connectedDeviceName: String?
    @Published var currentFrame: NSImage?
    @Published var frameRate: Double = 0
    @Published var latencyMs: Int = 0
    @Published var bytesReceived: Int = 0
    @Published var receivedMessages: [MetadataMessage] = []
    @Published var isReceivingVideo = false
    @Published var framesReceived: UInt32 = 0

    // MARK: - Private Properties

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var lastHeartbeatReceived = Date()
    private var isConnecting = false  // Guard against duplicate connections

    private var packetCount = 0
    private var lastStatsUpdate = Date()
    private var totalBytesReceived = 0
    private var videoFrameCount: UInt32 = 0

    private let deviceName: String

    // Video decoding
    private let decoder = LowLatencyDecoder()

    // MARK: - Initialization

    init() {
        self.deviceName = Host.current().localizedName ?? "Mac"
        setupDecoder()
    }

    private func setupDecoder() {
        decoder.setDecodedCallback { [weak self] pixelBuffer, _ in
            guard let self else { return }
            if let image = pixelBuffer.toNSImage() {
                self.currentFrame = image
                self.videoFrameCount += 1
                self.framesReceived = self.videoFrameCount
                if !self.isReceivingVideo {
                    self.isReceivingVideo = true
                }
            }
        }
    }

    // MARK: - Public Methods

    func startDiscovery() {
        // Guard against starting discovery while already connecting or connected
        guard !isConnecting && !isConnected else {
            print("[Receiver] ⚠️ Already connecting or connected, ignoring startDiscovery")
            return
        }

        // Clean up any existing browser
        browser?.cancel()
        browser = nil

        connectionStatus = "Searching..."
        print("[Receiver] 🔍 Starting Bonjour discovery for _metastream._udp")

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(
            for: .bonjour(type: "_metastream._udp", domain: "local."),
            using: parameters
        )

        browser?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Receiver] Browser state: \(state)")
                switch state {
                case .setup:
                    print("[Receiver] Browser setup...")
                case .ready:
                    print("[Receiver] ✅ Browser ready, searching...")
                    self.connectionStatus = "Searching for iPhone..."
                case .failed(let error):
                    print("[Receiver] ❌ Browser failed: \(error)")
                    self.connectionStatus = "Discovery failed: \(error.localizedDescription)"
                case .cancelled:
                    print("[Receiver] Browser cancelled")
                case .waiting(let error):
                    print("[Receiver] ⏳ Browser waiting: \(error)")
                @unknown default:
                    print("[Receiver] Browser unknown state")
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Guard against connecting if already connecting or connected
                guard !self.isConnecting && !self.isConnected else {
                    return
                }
                print("[Receiver] 📡 Browse results changed: \(results.count) services found")
                for result in results {
                    print("[Receiver]   - \(result.endpoint)")
                }
                if let result = results.first {
                    print("[Receiver] Connecting to first result: \(result.endpoint)")
                    self.connectToDevice(result)
                }
            }
        }

        browser?.start(queue: .main)
        print("[Receiver] Browser started")
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        browser?.cancel()
        browser = nil

        connection?.cancel()
        connection = nil

        decoder.stop()

        isConnected = false
        isConnecting = false
        isReceivingVideo = false
        connectionStatus = "Disconnected"
        connectedDeviceName = nil
        currentFrame = nil
        frameRate = 0
        latencyMs = 0
        bytesReceived = 0
        framesReceived = 0
        videoFrameCount = 0
    }

    func sendMessage(_ text: String) {
        guard isConnected else { return }

        let metadata = MetadataMessage(
            deviceName: deviceName,
            deviceType: .mac,
            message: text
        )

        guard let packet = metadata.toPacket() else { return }
        sendPacket(packet)
    }

    // MARK: - Private Methods

    private func connectToDevice(_ result: NWBrowser.Result) {
        // Guard against duplicate connections
        guard !isConnecting && !isConnected else {
            print("[Receiver] ⚠️ Already connecting or connected, ignoring")
            return
        }

        isConnecting = true

        // Stop browsing once we find a device
        print("[Receiver] 🔗 Connecting to device: \(result.endpoint)")
        browser?.cancel()
        browser = nil

        connectionStatus = "Connecting..."

        let endpoint = result.endpoint
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true

        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[Receiver] Connection state: \(state)")
                switch state {
                case .ready:
                    print("[Receiver] ✅ Connection ready, sending handshake")
                    self.connectionStatus = "Handshaking..."
                    self.sendHandshake()
                    self.startReceiving()
                    self.startHeartbeatMonitor()
                case .failed(let error):
                    print("[Receiver] ❌ Connection failed: \(error)")
                    self.handleDisconnection(reason: error.localizedDescription)
                case .cancelled:
                    print("[Receiver] Connection cancelled")
                    // Don't auto-reconnect on explicit cancel
                case .preparing:
                    print("[Receiver] Connection preparing...")
                case .waiting(let error):
                    print("[Receiver] ⏳ Connection waiting: \(error)")
                case .setup:
                    print("[Receiver] Connection setup...")
                @unknown default:
                    print("[Receiver] Connection unknown state")
                }
            }
        }

        connection?.start(queue: .main)
        print("[Receiver] Connection started")
    }

    private func sendHandshake() {
        print("[Receiver] 🤝 Sending handshake as '\(deviceName)'")
        let handshake = HandshakePayload(deviceName: deviceName, deviceType: .mac)
        guard let packet = handshake.toPacket() else {
            print("[Receiver] ❌ Failed to create handshake packet")
            return
        }
        sendPacket(packet)
        print("[Receiver] ✅ Handshake sent")
    }

    private func startReceiving() {
        receiveNextPacket()
    }

    private func receiveNextPacket() {
        connection?.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data = content {
                    self.handleRawData(data)
                }

                if error == nil, self.connection != nil {
                    self.receiveNextPacket()
                }
            }
        }
    }

    private func handleRawData(_ data: Data) {
        totalBytesReceived += data.count
        packetCount += 1
        updateStats()
        bytesReceived = totalBytesReceived

        guard let packet = Packet(data: data) else {
            print("[Receiver] ❌ Invalid packet received (\(data.count) bytes)")
            return
        }

        handlePacket(packet)
    }

    private func handlePacket(_ packet: Packet) {
        switch packet.type {
        case .handshakeAck:
            print("[Receiver] 📦 Received handshakeAck")
            if let handshake = HandshakePayload.from(packet: packet) {
                print("[Receiver] ✅ Connected to: \(handshake.deviceName)")
                connectedDeviceName = handshake.deviceName
                isConnected = true
                isConnecting = false
                connectionStatus = "Connected to \(handshake.deviceName)"
            }

        case .handshake:
            print("[Receiver] 📦 Received handshake")
            // iPhone sent handshake, respond with ack
            if let handshake = HandshakePayload.from(packet: packet) {
                print("[Receiver] 🤝 Handshake from: \(handshake.deviceName)")
                connectedDeviceName = handshake.deviceName
                isConnected = true
                isConnecting = false
                connectionStatus = "Connected to \(handshake.deviceName)"

                // Send ack
                let ack = HandshakePayload(deviceName: deviceName, deviceType: .mac)
                if let ackPacket = ack.toPacket() {
                    var ackData = ackPacket.toData()
                    ackData[4] = PacketType.handshakeAck.rawValue
                    sendRawData(ackData)
                    print("[Receiver] ✅ Sent handshake ack")
                }
            }

        case .metadata:
            if let metadata = MetadataMessage.from(packet: packet) {
                print("[Receiver] 💬 Message from \(metadata.deviceName): \(metadata.message ?? "")")
                receivedMessages.append(metadata)
                if receivedMessages.count > 50 {
                    receivedMessages.removeFirst()
                }
            }

        case .heartbeat:
            lastHeartbeatReceived = Date()
            // Respond to heartbeat (don't log every heartbeat to reduce noise)
            sendPacket(Packet(type: .heartbeat))

        case .video:
            handleVideoPacket(packet)
        }
    }

    private func handleVideoPacket(_ packet: Packet) {
        guard let header = VideoFrameHeader(data: packet.payload) else {
            print("[Receiver] ❌ Invalid video header")
            return
        }

        // Handle parameter sets (SPS/PPS)
        if header.hasParameterSets {
            if let params = ParameterSetsPacket(packet: packet) {
                print("[Receiver] 📹 Received SPS/PPS")
                decoder.configure(sps: params.sps, pps: params.pps)
            }
            return
        }

        // Handle video frame
        if let videoFrame = VideoFramePacket(packet: packet) {
            decoder.decode(videoFrame.nalData)

            // Log periodically
            if videoFrame.header.frameNumber % 100 == 0 {
                print("[Receiver] 📹 Received frame \(videoFrame.header.frameNumber)")
            }
        }
    }

    private func startHeartbeatMonitor() {
        lastHeartbeatReceived = Date()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Send heartbeat
                self.sendPacket(Packet(type: .heartbeat))

                // Check for timeout (5 seconds without heartbeat)
                let elapsed = Date().timeIntervalSince(self.lastHeartbeatReceived)
                if elapsed > 5.0 && self.isConnected {
                    self.handleDisconnection(reason: "Heartbeat timeout")
                }
            }
        }
    }

    private func handleDisconnection(reason: String) {
        print("[Receiver] ⚠️ Disconnection: \(reason)")

        isConnected = false
        isConnecting = false
        connectedDeviceName = nil
        connectionStatus = "Disconnected: \(reason)"

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        connection?.cancel()
        connection = nil

        // Reset decoder for fresh start
        decoder.stop()
        isReceivingVideo = false

        // Auto-reconnect after a brief delay
        print("[Receiver] 🔄 Will auto-reconnect in 2 seconds...")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Only reconnect if still disconnected
            if !self.isConnected && !self.isConnecting {
                print("[Receiver] 🔄 Auto-reconnecting...")
                self.startDiscovery()
            }
        }
    }

    private func sendPacket(_ packet: Packet) {
        sendRawData(packet.toData())
    }

    private func sendRawData(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[Receiver] Send error: \(error)")
            }
        })
    }

    private func updateStats() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsUpdate)

        if elapsed >= 1.0 {
            frameRate = Double(packetCount) / elapsed
            packetCount = 0
            lastStatsUpdate = now
        }
    }
}
