import Foundation
import WebKit

/// The camera and the microphone a page of the app's own origin asks for (a video call over WebRTC): granted only to
/// an app whose Info.plist says why it uses each (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`). Pure.
public enum MediaGrant {

    /// The purpose strings [type] needs, all present in [bundle].
    public static func declared(_ type: WKMediaCaptureType, in bundle: Bundle) -> Bool {
        keys(type).map { $0.allSatisfy { bundle.object(forInfoDictionaryKey: $0) != nil } } ?? false
    }

    static func keys(_ type: WKMediaCaptureType) -> [String]? {
        switch type {
        case .camera: return ["NSCameraUsageDescription"]
        case .microphone: return ["NSMicrophoneUsageDescription"]
        case .cameraAndMicrophone: return ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]
        @unknown default: return nil
        }
    }
}
