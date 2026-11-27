import Foundation
import ImageIO
import PhastPhotoImaging
import Vision

public enum VisionError: Error, Hashable, Sendable {
    /// The Vision call did not finish in time. The work itself cannot be cancelled and keeps running on its
    /// queue until Vision returns; its result is discarded.
    case timedOut(seconds: Double)
    case failed(String)
}

/// Resumes a continuation exactly once, from whichever of the work and the timer finishes first.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

private let visionQueue = DispatchQueue(label: "phastphoto.vision", qos: .userInitiated, attributes: .concurrent)

/// Runs blocking Vision `work` off the caller's executor and gives up after `seconds`.
///
/// A task group would wait for the Vision call (it cannot be cancelled) and so never time out; this races a
/// timer against the work with one continuation instead. Vision itself keeps running after a timeout.
func withVisionTimeout<T: Sendable>(seconds: Double?, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let race = Race(continuation)
        visionQueue.async { race.finish(Result { try work() }) }
        if let seconds {
            visionQueue.asyncAfter(deadline: .now() + seconds) { race.finish(.failure(VisionError.timedOut(seconds: seconds))) }
        }
    }
}

enum VisionOrientations {
    /// Order shared with `tools/orient.swift`: index * 90 is the clockwise rotation the photo is judged to have.
    static let all: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
}

/// Runs `request` on `image`; throws on a Vision error. Orientation is always passed explicitly, never read
/// from EXIF.
func perform(_ request: VNRequest, on image: CGImage, orientation: CGImagePropertyOrientation = .up) throws {
    do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request]) } catch {
        throw VisionError.failed("\(error)")
    }
}

public enum VisionWarmUp {
    /// Runs one tiny request of each kind so the first real call is fast. On an Apple silicon Mac the first
    /// Vision call at a new app path can take about a minute (model compilation); call this at launch.
    public static func run(timeout: Double? = 180) async {
        let image = RGBImage(width: 64, height: 64, fill: RGB(128, 128, 128)).cgImage()
        _ = try? await withVisionTimeout(seconds: timeout) {
            try? perform(VNClassifyImageRequest(), on: image)
            try? perform(VNDetectFaceRectanglesRequest(), on: image)
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.automaticallyDetectsLanguage = true
            try? perform(text, on: image)
            return true
        }
    }
}
