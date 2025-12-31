//
//  LowLatencyEncoder.swift
//  metastreamRelay
//
//  H.264 hardware encoder using VideoToolbox
//  Optimized for low-latency streaming with real-time encoding
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

#if os(iOS)
import UIKit
#endif

/// Callback for encoded NAL units ready to send
typealias EncodedFrameCallback = (Data, Bool) -> Void  // (nalData, isKeyframe)

/// Low-latency H.264 encoder using VideoToolbox
class LowLatencyEncoder {

    // MARK: - Properties

    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var encodedCallback: EncodedFrameCallback?

    // Encoder settings
    private let bitrate: Int
    private let maxKeyframeInterval: Int
    private let expectedFrameRate: Float

    // Parameter sets (SPS/PPS) - needed by decoder
    private(set) var sps: Data?
    private(set) var pps: Data?
    private var parameterSetsExtracted = false

    // MARK: - Initialization

    /// Initialize encoder with target settings
    /// - Parameters:
    ///   - bitrate: Target bitrate in bits per second (default 2 Mbps)
    ///   - maxKeyframeInterval: Maximum frames between keyframes (default 60 = ~2.5 sec at 24fps)
    ///   - frameRate: Expected frame rate (default 24)
    init(bitrate: Int = 2_000_000, maxKeyframeInterval: Int = 60, frameRate: Float = 24.0) {
        self.bitrate = bitrate
        self.maxKeyframeInterval = maxKeyframeInterval
        self.expectedFrameRate = frameRate
        print("[Encoder] Initialized: \(bitrate/1000)kbps, keyframe every \(maxKeyframeInterval) frames")
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start the encoder
    /// - Parameters:
    ///   - width: Video width
    ///   - height: Video height
    ///   - callback: Called with each encoded NAL unit
    func start(width: Int32, height: Int32, callback: @escaping EncodedFrameCallback) {
        self.encodedCallback = callback

        guard compressionSession == nil else {
            print("[Encoder] Already started")
            return
        }

        print("[Encoder] Starting: \(width)x\(height)")

        // Encoder specification - prefer hardware encoder
        var encoderSpec: [CFString: Any] = [:]
        if #available(iOS 17.4, macOS 14.4, *) {
            encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
            encoderSpec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = false
        }

        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("[Encoder] Failed to create session: \(status)")
            return
        }

        compressionSession = session
        configureSession(session, width: width, height: height)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[Encoder] Session created and prepared")
    }

    /// Encode a video frame
    /// - Parameter sampleBuffer: CMSampleBuffer from camera
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Force keyframe on first frame or periodically
        var properties: [CFString: Any]? = nil
        if frameCount % Int64(maxKeyframeInterval) == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            print("[Encoder] Encode failed: \(status)")
        }

        frameCount += 1
    }

    /// Request a keyframe on next encode
    func forceKeyframe() {
        // Next encode call will have keyframe flag
        frameCount = 0
    }

    /// Stop the encoder
    func stop() {
        guard let session = compressionSession else { return }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        frameCount = 0
        parameterSetsExtracted = false
        sps = nil
        pps = nil
        print("[Encoder] Stopped")
    }

    // MARK: - Private Methods

    private func configureSession(_ session: VTCompressionSession, width: Int32, height: Int32) {
        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile - Baseline for maximum compatibility
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                            value: kVTProfileLevel_H264_Baseline_AutoLevel)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                            value: bitrate as CFNumber)

        // Data rate limits (peak bitrate)
        let bytesPerSecond = Double(bitrate) / 8.0
        let dataRateLimits = [bytesPerSecond * 1.5, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                            value: dataRateLimits)

        // Keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                            value: maxKeyframeInterval as CFNumber)

        // Frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                            value: expectedFrameRate as CFNumber)

        // Allow frame reordering disabled for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                            value: kCFBooleanFalse)

        // Low latency settings (iOS 15.4+)
        if #available(iOS 15.4, macOS 12.3, *) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                value: 51 as CFNumber)
        }

        print("[Encoder] Session configured")
    }

    /// Handle encoded output from VideoToolbox
    fileprivate func handleEncodedFrame(status: OSStatus, infoFlags: VTEncodeInfoFlags,
                                         sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            print("[Encoder] Output error: \(status)")
            return
        }

        guard let sampleBuffer = sampleBuffer else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = false
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(attachment,
                                               Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            isKeyframe = notSync == nil
        }

        // Extract SPS/PPS from keyframes
        if isKeyframe && !parameterSetsExtracted {
            extractParameterSets(from: sampleBuffer)
        }

        // Convert to NAL units
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let lengthStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard lengthStatus == noErr, let dataPointer = dataPointer else { return }

        // Parse AVCC format NAL units and convert to Annex-B
        var offset = 0
        let data = Data(bytes: dataPointer, count: totalLength)

        while offset < totalLength - 4 {
            // Read 4-byte length prefix (AVCC format)
            let nalLength = Int(data[offset]) << 24 |
                           Int(data[offset + 1]) << 16 |
                           Int(data[offset + 2]) << 8 |
                           Int(data[offset + 3])
            offset += 4

            guard offset + nalLength <= totalLength else { break }

            // Create Annex-B formatted NAL unit
            var annexBData = Data([0x00, 0x00, 0x00, 0x01])  // Start code
            annexBData.append(data.subdata(in: offset..<(offset + nalLength)))

            // Send to callback
            encodedCallback?(annexBData, isKeyframe)

            offset += nalLength
        }
    }

    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Get SPS
        var spsSize = 0
        var spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?

        var spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)

        if spsStatus == noErr, let spsPointer = spsPointer {
            var spsData = Data([0x00, 0x00, 0x00, 0x01])  // Annex-B start code
            spsData.append(Data(bytes: spsPointer, count: spsSize))
            self.sps = spsData
            print("[Encoder] Extracted SPS: \(spsSize) bytes")
        }

        // Get PPS
        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?

        spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if spsStatus == noErr, let ppsPointer = ppsPointer {
            var ppsData = Data([0x00, 0x00, 0x00, 0x01])  // Annex-B start code
            ppsData.append(Data(bytes: ppsPointer, count: ppsSize))
            self.pps = ppsData
            print("[Encoder] Extracted PPS: \(ppsSize) bytes")
        }

        if sps != nil && pps != nil {
            parameterSetsExtracted = true
        }
    }
}

// MARK: - VideoToolbox Callback

private func encoderOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<LowLatencyEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}
