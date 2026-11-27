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
        // Developer CLI for checking the library against a real scanner (macOS).
        .executable(name: "phastphoto", targets: ["phastphoto"]),
    ],
    targets: [
        .target(name: "PhastPhotoProtocol"),
        .target(name: "PhastPhotoScanner", dependencies: ["PhastPhotoProtocol"]),
        .executableTarget(name: "phastphoto", dependencies: ["PhastPhotoScanner"]),
        .testTarget(name: "PhastPhotoProtocolTests", dependencies: ["PhastPhotoProtocol"]),
        .testTarget(name: "PhastPhotoScannerTests", dependencies: ["PhastPhotoScanner", "PhastPhotoProtocol"]),
    ]
)
