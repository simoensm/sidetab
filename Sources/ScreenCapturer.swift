import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        "macOS never listed the SideTab display as something that can be captured."
    }
}

/// Grabs the picture of one display with ScreenCaptureKit and hands each new
/// frame to `onFrame`. macOS only delivers a frame when something on screen changed.
/// Everything here runs on `queue`.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer) -> Void
    private let onStop: (Error) -> Void
    private var stream: SCStream?
    private var cancelled = false

    init(queue: DispatchQueue,
         onFrame: @escaping (CVPixelBuffer) -> Void,
         onStop: @escaping (Error) -> Void) {
        self.queue = queue
        self.onFrame = onFrame
        self.onStop = onStop
        super.init()
    }

    func start(displayID: CGDirectDisplayID,
               pixelsWide: Int,
               pixelsHigh: Int,
               fps: Int,
               attempt: Int = 1,
               completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard !self.cancelled else { return }
                if let error {
                    completion(error)
                    return
                }
                guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                    // A brand-new display can take a moment to show up in this list.
                    guard attempt < 20 else {
                        completion(CaptureError.displayNotFound)
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.25) {
                        self.start(displayID: displayID, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                   fps: fps, attempt: attempt + 1, completion: completion)
                    }
                    return
                }

                let configuration = SCStreamConfiguration()
                configuration.width = pixelsWide
                configuration.height = pixelsHigh
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                // The encoder's native input format, so no colour conversion on the way.
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                configuration.showsCursor = true
                configuration.queueDepth = 4

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    completion(error)
                    return
                }
                self.stream = stream
                stream.startCapture { error in
                    completion(error)
                }
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.cancelled = true
            guard let stream = self.stream else {
                completion()
                return
            }
            self.stream = nil
            stream.stopCapture { _ in
                completion()
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !cancelled, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
