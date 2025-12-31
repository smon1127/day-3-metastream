//
//  LowLatencyDecoder.swift
//  metastreamRelay
//
//  H.264 hardware decoder using VideoToolbox
//  Optimized for low-latency streaming
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Callback for decoded frames
typealias DecodedFrameCallback = (CVPixelBuffer, CMTime) -> Void

/// Low-latency H.264 decoder using VideoToolbox
class LowLatencyDecoder {

    // MARK: - Properties

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var decodedCallback: DecodedFrameCallback?

    // Buffered parameter sets
    private var spsData: Data?
    private var ppsData: Data?
    private var sessionConfigured = false

    // MARK: - Initialization

    init() {
        print("[Decoder] Initialized")
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Set the callback for decoded frames
    func setDecodedCallback(_ callback: @escaping DecodedFrameCallback) {
        self.decodedCallback = callback
    }

    /// Decode a NAL unit (Annex-B format with start code)
    /// - Parameter nalData: NAL unit data including 0x00000001 start code
    func decode(_ nalData: Data) {
        guard nalData.count > 4 else { return }

        // Skip start code and get NAL type
        let startCodeLength = detectStartCodeLength(nalData)
        guard startCodeLength > 0 else { return }

        let nalType = nalData[startCodeLength] & 0x1F

        switch nalType {
        case 7:  // SPS
            spsData = nalData
            print("[Decoder] Received SPS: \(nalData.count) bytes")
            tryConfigureSession()
        case 8:  // PPS
            ppsData = nalData
            print("[Decoder] Received PPS: \(nalData.count) bytes")
            tryConfigureSession()
        case 5:  // IDR (keyframe)
            if sessionConfigured {
                decodeFrame(nalData, isKeyframe: true)
            } else {
                print("[Decoder] IDR received but session not configured, waiting for SPS/PPS")
            }
        case 1:  // Non-IDR (P-frame)
            if sessionConfigured {
                decodeFrame(nalData, isKeyframe: false)
            }
        default:
            print("[Decoder] Unknown NAL type: \(nalType)")
        }
    }

    /// Configure decoder with SPS/PPS directly
    func configure(sps: Data, pps: Data) {
        self.spsData = sps
        self.ppsData = pps
        tryConfigureSession()
    }

    /// Stop the decoder
    func stop() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        sessionConfigured = false
        spsData = nil
        ppsData = nil
        decodedFrameCount = 0
        print("[Decoder] Stopped")
    }

    /// Reset decoder (request new keyframe from encoder)
    func reset() {
        stop()
    }

    // MARK: - Private Methods

    private func detectStartCodeLength(_ data: Data) -> Int {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return 4
        } else if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return 3
        }
        return 0
    }

    private func tryConfigureSession() {
        guard let spsData = spsData, let ppsData = ppsData else { return }
        guard !sessionConfigured else { return }

        // Extract raw parameter data (skip start codes)
        let spsStartCode = detectStartCodeLength(spsData)
        let ppsStartCode = detectStartCodeLength(ppsData)

        let spsRaw = spsData.subdata(in: spsStartCode..<spsData.count)
        let ppsRaw = ppsData.subdata(in: ppsStartCode..<ppsData.count)

        // Create format description from parameter sets
        var formatDesc: CMVideoFormatDescription?

        spsRaw.withUnsafeBytes { spsBuffer in
            ppsRaw.withUnsafeBytes { ppsBuffer in
                var pointers = [spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                               ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                var sizes = [spsRaw.count, ppsRaw.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )

                if status != noErr {
                    print("[Decoder] Failed to create format description: \(status)")
                    return
                }
            }
        }

        guard let formatDesc = formatDesc else {
            print("[Decoder] No format description created")
            return
        }

        self.formatDescription = formatDesc

        // Get video dimensions
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        print("[Decoder] Video dimensions: \(dimensions.width)x\(dimensions.height)")

        // Create decompression session
        let destAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard createStatus == noErr, let session = session else {
            print("[Decoder] Failed to create decompression session: \(createStatus)")
            return
        }

        // Configure for low latency
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        decompressionSession = session
        sessionConfigured = true
        print("[Decoder] Session configured successfully")
    }

    private func decodeFrame(_ nalData: Data, isKeyframe: Bool) {
        guard let session = decompressionSession, let formatDesc = formatDescription else {
            return
        }

        // Convert Annex-B to AVCC format (replace start code with length)
        let startCodeLength = detectStartCodeLength(nalData)
        let payloadLength = nalData.count - startCodeLength

        var avccData = Data()
        // Write 4-byte length prefix (big endian)
        avccData.append(UInt8((payloadLength >> 24) & 0xFF))
        avccData.append(UInt8((payloadLength >> 16) & 0xFF))
        avccData.append(UInt8((payloadLength >> 8) & 0xFF))
        avccData.append(UInt8(payloadLength & 0xFF))
        // Append NAL payload
        avccData.append(nalData.subdata(in: startCodeLength..<nalData.count))

        // Create block buffer
        var blockBuffer: CMBlockBuffer?

        avccData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }

            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            if let blockBuffer = blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: ptr,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: avccData.count
                )
            }
        }

        guard let blockBuffer = blockBuffer else { return }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24),  // Assume 24fps
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleSize = avccData.count

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            print("[Decoder] Failed to create sample buffer: \(sampleStatus)")
            return
        }

        // Decode
        var decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        if !isKeyframe {
            decodeFlags.insert(._EnableTemporalProcessing)
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if decodeStatus != noErr {
            print("[Decoder] Decode error: \(decodeStatus)")
        }
    }

    /// Handle decoded output from VideoToolbox
    private var decodedFrameCount: UInt32 = 0

    fileprivate func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?,
                                         presentationTimeStamp: CMTime) {
        guard status == noErr else {
            print("[Decoder] Output error: \(status)")
            return
        }

        guard let pixelBuffer = imageBuffer else {
            print("[Decoder] ⚠️ No image buffer in callback")
            return
        }

        decodedFrameCount += 1
        if decodedFrameCount == 1 || decodedFrameCount % 100 == 0 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("[Decoder] ✅ Decoded frame #\(decodedFrameCount) (\(width)x\(height))")
        }

        // Callback on main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            self?.decodedCallback?(pixelBuffer, presentationTimeStamp)
        }
    }
}

// MARK: - VideoToolbox Callback

private func decoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<LowLatencyDecoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer,
                               presentationTimeStamp: presentationTimeStamp)
}

// MARK: - CVPixelBuffer to NSImage/UIImage Extension

extension CVPixelBuffer {
    #if os(macOS)
    func toNSImage() -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0,
                                                                         width: width, height: height)) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
    #else
    func toUIImage() -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0,
                                                                         width: width, height: height)) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
    #endif
}
