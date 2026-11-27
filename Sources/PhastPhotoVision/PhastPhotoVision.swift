import Foundation

/// On-device analysis of scanned prints with Apple's Vision framework: reading the backs of prints,
/// orientation from faces and scenes, and finding eyes for red-eye removal.
///
/// Vision results on the iOS simulator are not real; check behaviour on a device. On an Apple silicon Mac the
/// first Vision call at a new app path can take about a minute, so apps may want to warm it up at launch.
public enum PhastPhotoVision {}
