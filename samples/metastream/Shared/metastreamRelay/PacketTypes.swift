//
//  PacketTypes.swift
//  metastreamRelay
//
//  Created by Claude + humanwritten
//  Shared packet protocol for iOS-Mac communication
//

import Foundation

// MARK: - Packet Header

/// Magic bytes: "METS" (metastream)
let kPacketMagic: UInt32 = 0x4D455453

/// Packet types for the metastream protocol
enum PacketType: UInt8 {
    case handshake = 1    // Initial connection handshake
    case handshakeAck = 2 // Handshake acknowledgment
    case heartbeat = 3    // Keep-alive ping
    case metadata = 4     // JSON metadata (device info, messages)
    case video = 5        // Video frame data (Phase 4)
}

/// Packet header structure (9 bytes total)
/// - magic: 4 bytes (0x4D455453 = "METS")
/// - type: 1 byte (PacketType raw value)
/// - length: 4 bytes (payload length, big-endian)
struct PacketHeader {
    let magic: UInt32
    let type: PacketType
    let length: UInt32

    static let size = 9

    init(type: PacketType, payloadLength: UInt32) {
        self.magic = kPacketMagic
        self.type = type
        self.length = payloadLength
    }

    init?(data: Data) {
        guard data.count >= PacketHeader.size else { return nil }

        // Read magic (bytes 0-3) - use safe byte-by-byte reading
        let magic = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        guard magic == kPacketMagic else { return nil }

        // Read type (byte 4)
        guard let type = PacketType(rawValue: data[4]) else { return nil }

        // Read length (bytes 5-8) - use safe byte-by-byte reading to avoid alignment issues
        let length = UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])

        self.magic = magic
        self.type = type
        self.length = length
    }

    func toData() -> Data {
        var data = Data(capacity: PacketHeader.size)

        var magicBE = kPacketMagic.bigEndian
        data.append(Data(bytes: &magicBE, count: 4))

        data.append(type.rawValue)

        var lengthBE = length.bigEndian
        data.append(Data(bytes: &lengthBE, count: 4))

        return data
    }
}

// MARK: - Packet

struct Packet {
    let header: PacketHeader
    let payload: Data

    init(type: PacketType, payload: Data = Data()) {
        self.header = PacketHeader(type: type, payloadLength: UInt32(payload.count))
        self.payload = payload
    }

    init?(data: Data) {
        guard let header = PacketHeader(data: data) else { return nil }
        guard data.count >= PacketHeader.size + Int(header.length) else { return nil }

        self.header = header
        self.payload = data.subdata(in: PacketHeader.size..<(PacketHeader.size + Int(header.length)))
    }

    func toData() -> Data {
        var data = header.toData()
        data.append(payload)
        return data
    }

    var type: PacketType { header.type }
}

// MARK: - Metadata Message

/// Metadata payload for device info and text messages
struct MetadataMessage: Codable {
    let deviceName: String
    let deviceType: DeviceType
    let timestamp: Date
    let message: String?

    enum DeviceType: String, Codable {
        case iPhone
        case mac
    }

    init(deviceName: String, deviceType: DeviceType, message: String? = nil) {
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.timestamp = Date()
        self.message = message
    }

    func toPacket() -> Packet? {
        guard let jsonData = try? JSONEncoder().encode(self) else { return nil }
        return Packet(type: .metadata, payload: jsonData)
    }

    static func from(packet: Packet) -> MetadataMessage? {
        guard packet.type == .metadata else { return nil }
        return try? JSONDecoder().decode(MetadataMessage.self, from: packet.payload)
    }
}

// MARK: - Handshake Payload

/// Handshake payload for initial connection
struct HandshakePayload: Codable {
    let protocolVersion: Int
    let deviceName: String
    let deviceType: MetadataMessage.DeviceType

    static let currentVersion = 1

    init(deviceName: String, deviceType: MetadataMessage.DeviceType) {
        self.protocolVersion = Self.currentVersion
        self.deviceName = deviceName
        self.deviceType = deviceType
    }

    func toPacket() -> Packet? {
        guard let jsonData = try? JSONEncoder().encode(self) else { return nil }
        return Packet(type: .handshake, payload: jsonData)
    }

    static func from(packet: Packet) -> HandshakePayload? {
        guard packet.type == .handshake || packet.type == .handshakeAck else { return nil }
        return try? JSONDecoder().decode(HandshakePayload.self, from: packet.payload)
    }
}

// MARK: - Video Frame Packet

/// Video frame header (8 bytes)
/// - frameNumber: 4 bytes (sequence number for reordering)
/// - flags: 1 byte (bit 0 = keyframe, bit 1 = has SPS/PPS)
/// - nalType: 1 byte (H.264 NAL unit type)
/// - reserved: 2 bytes (for future use)
struct VideoFrameHeader {
    let frameNumber: UInt32
    let flags: UInt8
    let nalType: UInt8
    let reserved: UInt16

    static let size = 8

    var isKeyframe: Bool { flags & 0x01 != 0 }
    var hasParameterSets: Bool { flags & 0x02 != 0 }

    init(frameNumber: UInt32, isKeyframe: Bool, hasParameterSets: Bool, nalType: UInt8) {
        self.frameNumber = frameNumber
        var flagByte: UInt8 = 0
        if isKeyframe { flagByte |= 0x01 }
        if hasParameterSets { flagByte |= 0x02 }
        self.flags = flagByte
        self.nalType = nalType
        self.reserved = 0
    }

    init?(data: Data) {
        guard data.count >= VideoFrameHeader.size else { return nil }

        // Read frameNumber (bytes 0-3)
        frameNumber = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                     UInt32(data[2]) << 8 | UInt32(data[3])
        flags = data[4]
        nalType = data[5]
        reserved = UInt16(data[6]) << 8 | UInt16(data[7])
    }

    func toData() -> Data {
        var data = Data(capacity: VideoFrameHeader.size)

        // Write frameNumber big-endian
        data.append(UInt8((frameNumber >> 24) & 0xFF))
        data.append(UInt8((frameNumber >> 16) & 0xFF))
        data.append(UInt8((frameNumber >> 8) & 0xFF))
        data.append(UInt8(frameNumber & 0xFF))

        data.append(flags)
        data.append(nalType)

        // Reserved bytes
        data.append(UInt8((reserved >> 8) & 0xFF))
        data.append(UInt8(reserved & 0xFF))

        return data
    }
}

/// Video frame packet containing NAL unit data
struct VideoFramePacket {
    let header: VideoFrameHeader
    let nalData: Data  // NAL unit in Annex-B format (with start code)

    init(frameNumber: UInt32, nalData: Data, isKeyframe: Bool, hasParameterSets: Bool = false) {
        // Extract NAL type from the data (after start code)
        let startCodeLen = VideoFramePacket.detectStartCodeLength(nalData)
        let nalType: UInt8 = startCodeLen > 0 && nalData.count > startCodeLen
            ? nalData[startCodeLen] & 0x1F : 0

        self.header = VideoFrameHeader(
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            hasParameterSets: hasParameterSets,
            nalType: nalType
        )
        self.nalData = nalData
    }

    init?(packet: Packet) {
        guard packet.type == .video else { return nil }
        guard packet.payload.count >= VideoFrameHeader.size else { return nil }

        guard let header = VideoFrameHeader(data: packet.payload) else { return nil }
        self.header = header
        self.nalData = packet.payload.subdata(in: VideoFrameHeader.size..<packet.payload.count)
    }

    func toPacket() -> Packet {
        var payload = header.toData()
        payload.append(nalData)
        return Packet(type: .video, payload: payload)
    }

    private static func detectStartCodeLength(_ data: Data) -> Int {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return 4
        } else if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return 3
        }
        return 0
    }
}

// MARK: - Parameter Set Packet

/// SPS/PPS parameter sets packet (sent before keyframes)
struct ParameterSetsPacket {
    let sps: Data
    let pps: Data

    init(sps: Data, pps: Data) {
        self.sps = sps
        self.pps = pps
    }

    init?(packet: Packet) {
        guard packet.type == .video else { return nil }
        guard packet.payload.count >= VideoFrameHeader.size else { return nil }

        guard let header = VideoFrameHeader(data: packet.payload),
              header.hasParameterSets else { return nil }

        // Parse SPS/PPS from payload after header
        // Format: [spsLength(2)] [sps] [ppsLength(2)] [pps]
        let data = packet.payload.subdata(in: VideoFrameHeader.size..<packet.payload.count)
        guard data.count >= 4 else { return nil }

        let spsLen = Int(data[0]) << 8 | Int(data[1])
        guard data.count >= 2 + spsLen + 2 else { return nil }

        self.sps = data.subdata(in: 2..<(2 + spsLen))

        let ppsOffset = 2 + spsLen
        let ppsLen = Int(data[ppsOffset]) << 8 | Int(data[ppsOffset + 1])
        guard data.count >= ppsOffset + 2 + ppsLen else { return nil }

        self.pps = data.subdata(in: (ppsOffset + 2)..<(ppsOffset + 2 + ppsLen))
    }

    func toPacket(frameNumber: UInt32) -> Packet {
        let header = VideoFrameHeader(
            frameNumber: frameNumber,
            isKeyframe: true,
            hasParameterSets: true,
            nalType: 7  // SPS type
        )

        var payload = header.toData()

        // Write SPS length + data
        payload.append(UInt8((sps.count >> 8) & 0xFF))
        payload.append(UInt8(sps.count & 0xFF))
        payload.append(sps)

        // Write PPS length + data
        payload.append(UInt8((pps.count >> 8) & 0xFF))
        payload.append(UInt8(pps.count & 0xFF))
        payload.append(pps)

        return Packet(type: .video, payload: payload)
    }
}
