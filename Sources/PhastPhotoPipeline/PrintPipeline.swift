import Foundation
import PhastPhotoImaging
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision

/// What happens to a picture that was already scanned (`duplicates` setting, `app.py:64`).
public enum DuplicateMode: String, Hashable, Sendable {
    /// Don't look.
    case off
    /// Save it anyway and report what it duplicates (ffscan's default).
    case flag
    /// Don't save it.
    case skip
}

/// The pipeline's settings: ffscan's per-page settings (`app.py:39-68`) with its defaults. Which sides are
/// scanned and kept comes from the print's ``SideMode``.
public struct PrintPipelineSettings: Equatable, Sendable {
    /// Crop each saved side to the print (``AutoCrop``). Backs are always cropped for reading, as upstream.
    /// Pages the scanner already cut to the paper (``ScannedPage/hardwareCropped``) are never cropped again:
    /// with no backing around them, software crop finds a wrong box.
    public var crop: Bool
    /// Drop backs with no writing (picture-and-back scans; never in back mode).
    public var skipBlankBacks: Bool
    /// Ink fraction below which a back without text is blank, and a fast-mode picture is a back.
    public var blankThreshold: Double
    public var duplicates: DuplicateMode
    /// Make an enhanced copy of each picture with these steps; `nil` for none (ffscan's default).
    public var enhancement: EnhancementOptions?
    /// Set the picture's orientation tag from faces or the scene.
    public var autoRotate: Bool
    /// Written into every saved file; empty fields are left alone. A picture's back text is added to it.
    public var metadata: PhotoMetadata

    public init(crop: Bool = true, skipBlankBacks: Bool = true, blankThreshold: Double = BackPolicy.blankThreshold,
                duplicates: DuplicateMode = .flag, enhancement: EnhancementOptions? = nil, autoRotate: Bool = true,
                metadata: PhotoMetadata = PhotoMetadata()) {
        self.crop = crop
        self.skipBlankBacks = skipBlankBacks
        self.blankThreshold = blankThreshold
        self.duplicates = duplicates
        self.enhancement = enhancement
        self.autoRotate = autoRotate
        self.metadata = metadata
    }
}

/// Why a side was not saved.
public enum SkipReason: Hashable, Sendable {
    case blankBack(ink: Double)
    /// Fast mode reads only the face-down side; a blank one means the prints were loaded face up.
    case facedUpInFastMode
    /// The picture was already scanned (``DuplicateMode/skip``).
    case duplicate(of: URL)

    /// ffscan's wording (`app.py:446`, `:454`, `:462`).
    public var message: String {
        switch self {
        case .blankBack(let ink): BackPolicy.Skip.blankBack(ink: ink).reason
        case .facedUpInFastMode: BackPolicy.Skip.facedUpInFastMode.reason
        case .duplicate(let url): "already scanned: \(url.lastPathComponent)"
        }
    }
}

/// A side to save, with everything the pipeline worked out for it.
public struct ProcessedSide: Sendable {
    /// B for the picture (fast mode's side is relabelled), A for the back.
    public var side: ScanSide
    /// The file to save: cropped (or the scan as sent), with metadata and the orientation tag.
    public var jpeg: Data
    /// The enhanced copy, with the same metadata and tag; pictures only, when enhancement is on.
    public var enhanced: Data?
    /// What the enhancement did, e.g. "restored colours".
    public var enhancementSteps: [String]
    /// Pictures only; "not decided" (0) for backs and when auto-rotation is off.
    public var rotation: RotationDecision
    /// An earlier picture of the same print (``DuplicateMode/flag``).
    public var duplicateOf: URL?
    /// The metadata written into ``jpeg`` and ``enhanced`` (including back text for a picture).
    public var metadata: PhotoMetadata
    /// Ink fraction of the saved image, when a rule needed it.
    public var ink: Double?
}

public enum SideOutcome: Sendable {
    case saved(ProcessedSide)
    case skipped(SkipReason)

    public var saved: ProcessedSide? {
        if case .saved(let side) = self { return side }
        return nil
    }

    public var skipReason: SkipReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

/// One print after the pipeline. A side the mode doesn't keep (or didn't scan) is `nil`.
public struct ProcessedPrint: Sendable {
    public var index: Int
    /// Writing read from the back (human-text filtered), "" when none or not read.
    public var backText: String
    /// Side A, when the mode keeps backs (both, back).
    public var back: SideOutcome?
    /// Side B, when the mode keeps pictures (picture, both, fast).
    public var picture: SideOutcome?
    /// Steps that failed without stopping the print, such as a Vision timeout.
    public var warnings: [String]

    /// Saved sides in scan order (back first).
    public var saved: [ProcessedSide] { [back, picture].compactMap { $0?.saved } }
}

/// Runs one scanned print through ffscan's per-side pipeline (`process_page`, `app.py:425-490`), in its order:
///
/// 1. Read the back's writing (crop a copy, ink at least 0.002, OCR, human-text filter).
/// 2. Side filter (``SideMode``).
/// 3. Crop.
/// 4. Blank back: drop side A when not in back mode, with no back text and ink under the threshold.
/// 5. Fast mode with crop on: drop a picture with ink under the threshold (prints loaded face up).
/// 6. Duplicate check (pictures, on the cropped file).
/// 7. Enhanced copy (pictures).
/// 8. Auto-rotation (pictures): faces, then the scene.
/// 9. Metadata (the picture gets "Written on back: ..." and a date from it if none was set), then the
///    orientation tag, on the file and its enhanced copy.
///
/// All pixel work is in stored orientation. Nothing is written to disk: the caller saves ``ProcessedSide/jpeg``
/// and ``ProcessedSide/enhanced``. Process prints in scan order, saving each before the next, so a later
/// print's duplicate check can find it.
public struct PrintPipeline: Sendable {
    /// Finds an earlier picture showing the same print as `jpeg` (the cropped picture, not yet saved), or nil.
    /// ``DuplicateIndex/findDuplicate(ofJPEG:in:)`` over the output folder's pictures is the usual answer.
    public typealias DuplicateFinder = @Sendable (_ jpeg: Data) async throws -> URL?

    public var settings: PrintPipelineSettings
    public var analyzer: any PrintAnalyzer
    /// Needed for ``DuplicateMode/flag`` and ``DuplicateMode/skip``; without one, no duplicate check runs.
    public var findDuplicate: DuplicateFinder?

    public init(settings: PrintPipelineSettings = PrintPipelineSettings(), analyzer: any PrintAnalyzer = VisionAnalyzer(),
                findDuplicate: DuplicateFinder? = nil) {
        self.settings = settings
        self.analyzer = analyzer
        self.findDuplicate = findDuplicate
    }

    /// Process a print from ``PrintAssembler``.
    public func process(_ print: AssembledPrint) async throws -> ProcessedPrint {
        let hardwareCropped = print.picture?.hardwareCropped ?? print.back?.hardwareCropped ?? false
        return try await process(index: print.index, mode: print.mode, picture: print.picture?.jpeg,
                                 back: print.back?.jpeg, hardwareCropped: hardwareCropped)
    }

    /// Process a print given as JPEG data, as the scanner sent it (backing included).
    /// - Parameters:
    ///   - picture: the picture side (side B; side A in fast mode), if scanned.
    ///   - back: the back of the print (side A in picture, both and back modes), if scanned.
    ///   - hardwareCropped: the scanner already cut both sides to the paper (``ScanSettings/hardwareCrop``):
    ///     skip software crop.
    public func process(index: Int, mode: SideMode, picture: Data?, back: Data?,
                        hardwareCropped: Bool = false) async throws -> ProcessedPrint {
        var result = ProcessedPrint(index: index, backText: "", back: nil, picture: nil, warnings: [])
        let sides = BackPolicy.Sides(mode)

        // 1. Back text, once per print: the back's own blank check and the picture's metadata use it. Back mode
        // uses neither, so it isn't read there.
        var backCrop: RGBImage?
        var backReadFailed = false
        if let back, mode != .back {
            let decoded = try RGBImage.decode(back)
            let crop = hardwareCropped ? decoded : AutoCrop.crop(decoded).image
            backCrop = crop
            do {
                result.backText = try await BackPolicy.readBack(ink: InkFraction.of(crop)) {
                    try await analyzer.humanBackText(crop)
                }
            } catch {
                backReadFailed = true
                result.warnings.append("couldn't read the back: \(error)")
            }
        }

        // 2. Side filter; then each kept side in scan order.
        if let back, mode.keeps(.a) {
            result.back = try await processBack(back, crop: backCrop, hardwareCropped: hardwareCropped, sides: sides,
                                                backText: result.backText, backReadFailed: backReadFailed)
        }
        if let picture, mode.keeps(.b) {
            result.picture = try await processPicture(picture, hardwareCropped: hardwareCropped, sides: sides,
                                                      backText: result.backText, warnings: &result.warnings)
        }
        return result
    }

    // MARK: - Sides

    private func processBack(_ raw: Data, crop: RGBImage?, hardwareCropped: Bool, sides: BackPolicy.Sides,
                             backText: String, backReadFailed: Bool) async throws -> SideOutcome {
        let (image, jpeg) = try cropped(raw, reusing: crop, hardwareCropped: hardwareCropped)
        var ink: Double?
        if settings.skipBlankBacks, sides != .back {  // the only rule for a back (`app.py:443`)
            let measured = InkFraction.of(image)
            ink = measured
            let skip = BackPolicy.skip(side: .a, sides: sides, skipBlankBacks: settings.skipBlankBacks,
                                       crop: settings.crop, backText: backText, ink: measured,
                                       blankThreshold: settings.blankThreshold)
            // A back that couldn't be read may have writing on it: keep it rather than drop it on ink alone.
            if let skip, !(backReadFailed && skip.isBlankBack) { return .skipped(SkipReason(skip)) }
        }
        let metadata = settings.metadata
        return .saved(ProcessedSide(side: .a, jpeg: try Self.finish(jpeg, metadata: metadata, rotation: 0),
                                    enhanced: nil, enhancementSteps: [],
                                    rotation: RotationDecision(degrees: 0, decided: false), duplicateOf: nil,
                                    metadata: metadata, ink: ink))
    }

    private func processPicture(_ raw: Data, hardwareCropped: Bool, sides: BackPolicy.Sides, backText: String,
                                warnings: inout [String]) async throws -> SideOutcome {
        let (image, jpeg) = try cropped(raw, reusing: nil, hardwareCropped: hardwareCropped)

        // 5. Fast mode: a blank face-down side is the back of a print loaded face up.
        var ink: Double?
        if sides == .fast, settings.crop {
            let measured = InkFraction.of(image)
            ink = measured
            if let skip = BackPolicy.skip(side: .b, sides: sides, skipBlankBacks: settings.skipBlankBacks,
                                          crop: settings.crop, backText: nil, ink: measured,
                                          blankThreshold: settings.blankThreshold) {
                return .skipped(SkipReason(skip))
            }
        }

        // 6. Duplicates, on the cropped picture.
        var duplicateOf: URL?
        if settings.duplicates != .off, let findDuplicate {
            do {
                duplicateOf = try await findDuplicate(jpeg)
            } catch {
                warnings.append("couldn't check for duplicates: \(error)")
            }
            if let duplicateOf, settings.duplicates == .skip { return .skipped(.duplicate(of: duplicateOf)) }
        }

        // 7. Enhanced copy, from the cropped picture before metadata (upstream copies the original's tags, then
        // writes metadata and rotation to both files).
        var enhanced: Data?
        var steps: [String] = []
        if let options = settings.enhancement {
            var eyes: [EyePosition] = []
            if options.redEye {
                do { eyes = try await analyzer.eyes(in: image) } catch {
                    warnings.append("couldn't find eyes for red-eye removal: \(error)")
                }
            }
            (enhanced, steps) = try RGBImage.enhancedCopy(of: jpeg, eyes: eyes, options: options)
        }

        // 8. Rotation.
        let rotation = settings.autoRotate ? await analyzer.rotation(of: image)
                                           : RotationDecision(degrees: 0, decided: false)

        // 9. Metadata with the back's writing, then the orientation tag.
        let date = BackText.date(from: backText).map(String.init(describing:)) ?? ""
        let metadata = settings.metadata.merging(backText: backText, dateFromBackText: date)
        return .saved(ProcessedSide(
            side: .b, jpeg: try Self.finish(jpeg, metadata: metadata, rotation: rotation.degrees),
            enhanced: try enhanced.map { try Self.finish($0, metadata: metadata, rotation: rotation.degrees) },
            enhancementSteps: steps, rotation: rotation, duplicateOf: duplicateOf, metadata: metadata, ink: ink))
    }

    // MARK: - Helpers

    /// 3. The side as it will be saved: cropped and re-encoded once at quality 0.95 with the scan's metadata, or
    /// the scan as sent when cropping is off or the scanner already cut it to the paper. Returns the pixels too,
    /// for ink and Vision. `crop` is the back's crop, already made for reading it.
    private func cropped(_ raw: Data, reusing crop: RGBImage?, hardwareCropped: Bool) throws -> (RGBImage, Data) {
        // the scanner's own cut: for a back, `crop` is that same decoded image
        if hardwareCropped { return (try crop ?? RGBImage.decode(raw), raw) }
        // crop off: the scan as sent (not the back's reading crop), like upstream's ink on the saved file
        guard settings.crop else { return (try RGBImage.decode(raw), raw) }
        let image = try crop ?? AutoCrop.crop(RGBImage.decode(raw)).image
        return (image, try image.jpegData(quality: 0.95, copyingMetadataFrom: raw))
    }

    /// Metadata (only when there is some, like `write_metadata`) and then the orientation tag (only when
    /// rotated, like `if rotation: set_rotation`), both without re-encoding.
    static func finish(_ jpeg: Data, metadata: PhotoMetadata, rotation: Int) throws -> Data {
        var out = jpeg
        if !metadata.isEmpty { out = try PhotoMetadata.write(metadata, to: out) }
        if rotation % 360 != 0 { out = try PhotoOrientation.setRotation(rotation, in: out) }
        return out
    }
}

// MARK: - Mapping onto the Vision module's own enums

extension BackPolicy.Sides {
    public init(_ mode: SideMode) {
        switch mode {
        case .picture: self = .picture
        case .both: self = .both
        case .back: self = .back
        case .fast: self = .fast
        }
    }
}

extension BackPolicy.Side {
    public init(_ side: ScanSide) {
        switch side {
        case .a: self = .a
        case .b: self = .b
        }
    }
}

extension SkipReason {
    init(_ skip: BackPolicy.Skip) {
        switch skip {
        case .blankBack(let ink): self = .blankBack(ink: ink)
        case .facedUpInFastMode: self = .facedUpInFastMode
        }
    }
}

extension BackPolicy.Skip {
    var isBlankBack: Bool {
        if case .blankBack = self { return true }
        return false
    }
}

extension PhotoMetadata {
    /// No field set: ffscan writes nothing then.
    var isEmpty: Bool { self == PhotoMetadata() }
}
