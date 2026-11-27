import Testing
@testable import PhastPhotoVision

@Suite struct PhastPhotoVisionModuleTests {
    @Test func moduleLoads() { _ = PhastPhotoVision.self }
}
