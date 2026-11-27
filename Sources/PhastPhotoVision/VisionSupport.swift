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

/// Resumes a continuation exactly once, from whichever of the work, the timer and task cancellation comes first.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early = pending {
            pending = nil
            lock.unlock()
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        if c == nil { pending = result }
        lock.unlock()
        c?.resume(with: result)
    }
}

private let visionQueue = DispatchQueue(label: "phastphoto.vision", qos: .userInitiated, attributes: .concurrent)
/// Timers run on their own queue so blocked Vision calls can never starve them.
private let timerQueue = DispatchQueue(label: "phastphoto.vision.timer", qos: .userInitiated)

/// Runs blocking Vision `work` off the caller's executor and gives up after `seconds` (or when the calling
/// task is cancelled, which throws `CancellationError`).
///
/// A task group would wait for the Vision call (it cannot be cancelled) and so never time out; this races a
/// timer against the work with one continuation instead. Vision itself keeps running after a timeout.
func withVisionTimeout<T: Sendable>(seconds: Double?, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.install(continuation)
            visionQueue.async { race.finish(Result { try work() }) }
            if let seconds {
                timerQueue.asyncAfter(deadline: .now() + seconds) { race.finish(.failure(VisionError.timedOut(seconds: seconds))) }
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
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
