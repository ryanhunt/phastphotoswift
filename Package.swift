// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhastPhoto",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Wire formats only: "IS" packets, ESC/I-2 tokens and commands, scan settings, JPEG fix-up.
        .library(name: "PhastPhotoProtocol", targets: ["PhastPhotoProtocol"]),
        // The scanner client: Bonjour discovery, Wi-Fi transport, sessions and scans.
        .library(name: "PhastPhotoScanner", targets: ["PhastPhotoScanner"]),
        // Image processing for scanned prints: crop, blank backs, and more (no scanner needed).
        .library(name: "PhastPhotoImaging", targets: ["PhastPhotoImaging"]),
        // Apple Vision analysis: back-of-print text, orientation, eyes.
        .library(name: "PhastPhotoVision", targets: ["PhastPhotoVision"]),
        // The per-print pipeline: back text, crop, blank backs, duplicates, enhanced copy, rotation, metadata.
        .library(name: "PhastPhotoPipeline", targets: ["PhastPhotoPipeline"]),
        // Developer CLI for checking the library against a real scanner (macOS).
        .executable(name: "phastphoto", targets: ["phastphoto"]),
    ],
    targets: [
        .target(name: "PhastPhotoProtocol"),
        .target(name: "PhastPhotoScanner", dependencies: ["PhastPhotoProtocol"]),
        .target(name: "PhastPhotoImaging"),
        .target(name: "PhastPhotoVision", dependencies: ["PhastPhotoImaging"]),
        .target(name: "PhastPhotoPipeline",
                dependencies: ["PhastPhotoProtocol", "PhastPhotoScanner", "PhastPhotoImaging", "PhastPhotoVision"]),
        .executableTarget(name: "phastphoto", dependencies: ["PhastPhotoScanner"]),
        .testTarget(name: "PhastPhotoProtocolTests", dependencies: ["PhastPhotoProtocol"]),
        .testTarget(name: "PhastPhotoScannerTests", dependencies: ["PhastPhotoScanner", "PhastPhotoProtocol"]),
        .testTarget(name: "PhastPhotoImagingTests", dependencies: ["PhastPhotoImaging"]),
        .testTarget(name: "PhastPhotoVisionTests", dependencies: ["PhastPhotoVision", "PhastPhotoImaging"]),
        .testTarget(name: "PhastPhotoPipelineTests",
                    dependencies: ["PhastPhotoPipeline", "PhastPhotoProtocol", "PhastPhotoScanner", "PhastPhotoImaging",
                                   "PhastPhotoVision"]),
    ]
)
