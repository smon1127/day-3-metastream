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

    // MARK: - Private Properties

    private var listener: NWListener?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?

    private let serviceType = "_metastream._udp"
    private let serviceName: String

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
        connection = nil
        isConnected = false
        connectedPeerName = nil
        statusMessage = "Disconnected: \(reason)"
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
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
        print("[Broadcaster] 📦 Received packet type: \(packet.type)")
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
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.sendPacket(Packet(type: .heartbeat))
            }
        }
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
