/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
//  NDIBroadcaster.swift
//  metastreamRelay
//
//  NDI video sender — broadcasts raw video frames over the local network
//  using the NDI SDK. Any NDI receiver (OBS, vMix, Wirecast, etc.) can
//  pick up the stream automatically.
//

import Accelerate
import CoreMedia
import CoreVideo
import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
class NDIBroadcaster: ObservableObject {
    @Published var isEnabled = false
    @Published var isSending = false
    @Published var statusMessage = "NDI off"
    @Published var currentFPS: Double = 0

    private var sendInstance: NDIlib_send_instance_t?
    private var ndiInitialized = false
    private let sourceName: String

    // FPS tracking
    private var framesSent: UInt64 = 0
    private var fpsFrameCount: UInt64 = 0
    private var fpsTimer: Timer?
    private var lastFPSUpdate: Date = .now

    // Reusable BGRA conversion buffer to avoid per-frame allocation
    private var bgraBuffer: UnsafeMutableRawPointer?
    private var bgraBufferSize = 0
    private var conversionInfo: vImage_YpCbCrToARGB?
    private var lastPixelFormat: OSType = 0

    init(sourceName: String? = nil) {
        #if os(iOS)
        self.sourceName = sourceName ?? "metastream (\(UIDevice.current.name))"
        #else
        self.sourceName = sourceName ?? "metastream"
        #endif
    }

    deinit {
        if let instance = sendInstance {
            NDIlib_send_destroy(instance)
        }
        bgraBuffer?.deallocate()
    }

    // MARK: - Public

    func start() {
        guard !isEnabled else { return }

        if !ndiInitialized {
            ndiInitialized = NDIlib_initialize()
            guard ndiInitialized else {
                statusMessage = "NDI init failed"
                print("[NDI] Failed to initialize NDI library")
                return
            }
            if let ver = NDIlib_version() {
                print("[NDI] Initialized — version \(String(cString: ver))")
            }
        }

        let nameUTF8 = sourceName.utf8CString
        let instance: NDIlib_send_instance_t? = nameUTF8.withUnsafeBufferPointer { namePtr in
            var settings = NDIlib_send_create_t()
            settings.p_ndi_name = namePtr.baseAddress
            settings.p_groups = nil
            settings.clock_video = true
            settings.clock_audio = true
            return NDIlib_send_create(&settings)
        }

        guard let instance else {
            statusMessage = "NDI send create failed"
            print("[NDI] Failed to create send instance")
            return
        }

        sendInstance = instance
        isEnabled = true
        isSending = false
        framesSent = 0
        fpsFrameCount = 0
        currentFPS = 0
        lastFPSUpdate = .now
        statusMessage = "NDI broadcasting as '\(sourceName)'"
        startFPSTimer()
        print("[NDI] Sender created: \(sourceName)")
    }

    func stop() {
        fpsTimer?.invalidate()
        fpsTimer = nil

        if let instance = sendInstance {
            NDIlib_send_destroy(instance)
            sendInstance = nil
        }

        bgraBuffer?.deallocate()
        bgraBuffer = nil
        bgraBufferSize = 0
        lastPixelFormat = 0

        isEnabled = false
        isSending = false
        framesSent = 0
        fpsFrameCount = 0
        currentFPS = 0
        statusMessage = "NDI off"
        print("[NDI] Sender destroyed")
    }

    func sendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isEnabled, let instance = sendInstance else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if pixelFormat == kCVPixelFormatType_32BGRA {
            sendBGRADirect(pixelBuffer, width: width, height: height, instance: instance)
        } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            sendNV12Converted(pixelBuffer, width: width, height: height, instance: instance)
        } else {
            if framesSent == 0 {
                let fourCC = String(format: "%c%c%c%c",
                                    (pixelFormat >> 24) & 0xFF, (pixelFormat >> 16) & 0xFF,
                                    (pixelFormat >> 8) & 0xFF, pixelFormat & 0xFF)
                print("[NDI] Unsupported pixel format: \(fourCC) (\(pixelFormat))")
            }
            return
        }

        if !isSending {
            isSending = true
            let fourCC = String(format: "%c%c%c%c",
                                (pixelFormat >> 24) & 0xFF, (pixelFormat >> 16) & 0xFF,
                                (pixelFormat >> 8) & 0xFF, pixelFormat & 0xFF)
            print("[NDI] First frame sent: \(width)x\(height) format=\(fourCC)")
        }

        framesSent += 1
        fpsFrameCount += 1
        if framesSent % 500 == 0 {
            print("[NDI] Sent \(framesSent) frames total, \(String(format: "%.1f", currentFPS)) fps")
        }
    }

    func getConnectionCount() -> Int {
        guard let instance = sendInstance else { return 0 }
        return Int(NDIlib_send_get_no_connections(instance, 0))
    }

    // MARK: - Private

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        lastFPSUpdate = .now
        fpsFrameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date.now
                let elapsed = now.timeIntervalSince(self.lastFPSUpdate)
                if elapsed > 0 {
                    self.currentFPS = Double(self.fpsFrameCount) / elapsed
                }
                self.fpsFrameCount = 0
                self.lastFPSUpdate = now
            }
        }
    }

    /// Fast path for BGRA buffers — zero-copy send.
    private func sendBGRADirect(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, instance: NDIlib_send_instance_t) {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var ndiFrame = NDIlib_video_frame_v2_t()
        ndiFrame.xres = Int32(width)
        ndiFrame.yres = Int32(height)
        ndiFrame.FourCC = NDIlib_FourCC_video_type_BGRA
        ndiFrame.frame_rate_N = 24000
        ndiFrame.frame_rate_D = 1000
        ndiFrame.picture_aspect_ratio = 0
        ndiFrame.frame_format_type = NDIlib_frame_format_type_progressive
        ndiFrame.timecode = Int64(NDIlib_send_timecode_synthesize)
        ndiFrame.p_data = baseAddress.assumingMemoryBound(to: UInt8.self)
        ndiFrame.line_stride_in_bytes = Int32(stride)
        ndiFrame.p_metadata = nil
        ndiFrame.timestamp = 0

        NDIlib_send_send_video_v2(instance, &ndiFrame)
    }

    /// Convert NV12 (420YpCbCr8BiPlanar) to BGRA, then send via NDI.
    private func sendNV12Converted(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, instance: NDIlib_send_instance_t) {
        let bgraStride = width * 4
        let requiredSize = bgraStride * height

        // (Re)allocate conversion buffer if needed
        if bgraBuffer == nil || bgraBufferSize < requiredSize {
            bgraBuffer?.deallocate()
            bgraBuffer = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
            bgraBufferSize = requiredSize
        }

        guard let bgraPtr = bgraBuffer else { return }

        // Set up vImage conversion if pixel format changed
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if conversionInfo == nil || lastPixelFormat != pixelFormat {
            setupConversion(pixelFormat: pixelFormat)
            lastPixelFormat = pixelFormat
        }

        guard var info = conversionInfo else { return }

        // Source planes from NV12 pixel buffer
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var srcY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yPlane),
                                 height: vImagePixelCount(height),
                                 width: vImagePixelCount(width),
                                 rowBytes: yStride)
        var srcCbCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: cbcrPlane),
                                    height: vImagePixelCount(height / 2),
                                    width: vImagePixelCount(width / 2),
                                    rowBytes: cbcrStride)
        var dstBGRA = vImage_Buffer(data: bgraPtr,
                                    height: vImagePixelCount(height),
                                    width: vImagePixelCount(width),
                                    rowBytes: bgraStride)

        // NV12 → BGRA conversion (hardware-accelerated via Accelerate)
        let permuteMap: [UInt8] = [3, 2, 1, 0]  // ARGB → BGRA
        let error = vImageConvert_420Yp8_CbCr8ToARGB8888(
            &srcY, &srcCbCr, &dstBGRA, &info, permuteMap, 255, vImage_Flags(kvImageNoFlags))

        guard error == kvImageNoError else {
            print("[NDI] vImage conversion error: \(error)")
            return
        }

        var ndiFrame = NDIlib_video_frame_v2_t()
        ndiFrame.xres = Int32(width)
        ndiFrame.yres = Int32(height)
        ndiFrame.FourCC = NDIlib_FourCC_video_type_BGRA
        ndiFrame.frame_rate_N = 24000
        ndiFrame.frame_rate_D = 1000
        ndiFrame.picture_aspect_ratio = 0
        ndiFrame.frame_format_type = NDIlib_frame_format_type_progressive
        ndiFrame.timecode = Int64(NDIlib_send_timecode_synthesize)
        ndiFrame.p_data = bgraPtr.assumingMemoryBound(to: UInt8.self)
        ndiFrame.line_stride_in_bytes = Int32(bgraStride)
        ndiFrame.p_metadata = nil
        ndiFrame.timestamp = 0

        NDIlib_send_send_video_v2(instance, &ndiFrame)
    }

    private func setupConversion(pixelFormat: OSType) {
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16,
            CbCrMax: 240, CbCrMin: 16
        )

        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            pixelRange = vImage_YpCbCrPixelRange(
                Yp_bias: 0, CbCr_bias: 128,
                YpRangeMax: 255, CbCrRangeMax: 255,
                YpMax: 255, YpMin: 0,
                CbCrMax: 255, CbCrMin: 1
            )
        }

        var info = vImage_YpCbCrToARGB()
        let error = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &pixelRange,
            &info,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )

        if error == kvImageNoError {
            conversionInfo = info
            print("[NDI] YpCbCr→BGRA conversion initialized")
        } else {
            print("[NDI] Failed to create conversion: \(error)")
        }
    }
}
