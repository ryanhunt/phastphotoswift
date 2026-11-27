import Foundation
import PhastPhotoImaging
import PhastPhotoVision

/// The Vision work the pipeline needs, behind a protocol so tests (and apps with their own models) can
/// inject results. ``VisionAnalyzer`` is the on-device implementation.
public protocol PrintAnalyzer: Sendable {
    /// Text read from a cropped back, before the human-text filter (the pipeline applies
    /// ``BackText/humanText(_:)``). Called only for backs with marks (ink at least ``BackPolicy/readThreshold``).
    func readBack(_ back: RGBImage) async throws -> String
    /// Which way up the (cropped) picture is. Return "not decided" rather than throwing when unsure.
    func rotation(of picture: RGBImage) async -> RotationDecision
    /// Eyes in the (cropped) picture's pixels, for red-eye removal. Called only when the enhanced copy is on
    /// with red-eye removal.
    func eyes(in picture: RGBImage) async throws -> [EyePosition]
}

/// ``PrintAnalyzer`` on Apple Vision: ``BackReader``, ``AutoRotation`` and ``EyeFinder`` with their
/// upstream sizes and thresholds. `timeout` is per Vision call (nil waits for ever).
public struct VisionAnalyzer: PrintAnalyzer {
    public var timeout: Double?

    public init(timeout: Double? = 120) { self.timeout = timeout }

    public func readBack(_ back: RGBImage) async throws -> String {
        try await BackReader.read(back, timeout: timeout).text
    }

    public func rotation(of picture: RGBImage) async -> RotationDecision {
        await AutoRotation.rotation(of: picture, timeout: timeout)
    }

    public func eyes(in picture: RGBImage) async throws -> [EyePosition] {
        try await EyeFinder.findEyes(in: picture, timeout: timeout).map(\.position)
    }
}
