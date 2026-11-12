import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum EncoderError: LocalizedError {
    case cannotCreateSession

    var errorDescription: String? {
        "The hardware H.264 encoder refused this resolution. Try a smaller --size or --no-hidpi."
    }
}

/// Hardware H.264 encoder set up for low delay: no B-frames, real-time mode.
///
/// Every output is one message for the viewer:
///   byte 0      1 for a keyframe, 0 otherwise
///   bytes 1...  the frame in Annex B form (NAL units separated by 00 00 00 01),
///               with SPS and PPS in front of every keyframe
final class H264Encoder {
    typealias Output = (_ message: Data, _ isKeyframe: Bool) -> Void

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private let session: VTCompressionSession
    private let output: Output
    private var lastTimestamp = CMTime.zero
    private var failureCount = 0

    /// True when VideoToolbox accepted its low-latency rate control mode.
    let usesLowLatencyRateControl: Bool

    init(width: Int, height: Int, fps: Int, bitrate: Int, output: @escaping Output) throws {
        func makeSession(lowLatency: Bool) -> VTCompressionSession? {
            let specification: CFDictionary? = lowLatency
                ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
                : nil
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created)
            return status == noErr ? created : nil
        }

        // Low-latency rate control is the better fit but is not offered for every
        // resolution, so fall back to the regular encoder when it is refused.
        var lowLatency = true
        var candidate = makeSession(lowLatency: true)
        if candidate == nil {
            lowLatency = false
            candidate = makeSession(lowLatency: false)
        }
        guard let created = candidate else { throw EncoderError.cannotCreateSession }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(created, key: key, value: value)
            if status != noErr {
                Log.info("Encoder skipped setting \(key) (status \(status))")
            }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // Keyframes are sent when a viewer asks for one, so the periodic ones can be rare.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 600))
        VTCompressionSessionPrepareToEncodeFrames(created)

        self.session = created
        self.output = output
        self.usesLowLatencyRateControl = lowLatency
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Call from one queue at a time.
    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        // Timestamps must keep increasing, including when a frame is encoded twice.
        var timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        if CMTimeCompare(timestamp, lastTimestamp) <= 0 {
            timestamp = CMTimeAdd(lastTimestamp, CMTime(value: 1, timescale: 1000))
        }
        lastTimestamp = timestamp

        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }

        if status != noErr {
            failureCount += 1
            if failureCount <= 5 {
                Log.info("Encoding a frame failed (status \(status))")
            }
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        // A frame is a keyframe unless it carries the "not sync" attachment.
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            isKeyframe = !CFDictionaryContainsKey(first, key)
        }

        let length = CMBlockBufferGetDataLength(block)
        var message = Data(capacity: length + 256)
        message.append(isKeyframe ? 1 : 0)

        // SPS and PPS travel in the format description, not in the frame data.
        var lengthFieldSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount = 0
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &lengthFieldSize)
            if isKeyframe {
                for index in 0..<parameterSetCount {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if status == noErr, let pointer {
                        message.append(contentsOf: H264Encoder.startCode)
                        message.append(pointer, count: size)
                    }
                }
            }
        }

        // VideoToolbox prefixes each NAL unit with its length; viewers want start codes.
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr
        else { return }

        let fieldSize = Int(lengthFieldSize)
        var offset = 0
        while offset + fieldSize <= length {
            var unitLength = 0
            for index in 0..<fieldSize {
                unitLength = (unitLength << 8) | Int(bytes[offset + index])
            }
            offset += fieldSize
            guard unitLength > 0, offset + unitLength <= length else { break }
            message.append(contentsOf: H264Encoder.startCode)
            message.append(contentsOf: bytes[offset..<(offset + unitLength)])
            offset += unitLength
        }

        output(message, isKeyframe)
    }
}
