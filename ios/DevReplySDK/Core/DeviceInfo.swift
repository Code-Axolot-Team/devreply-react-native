import Foundation
import UIKit

/// What an install tells the server about itself. No identifiers, no user data.
struct DeviceInfo: Sendable {
    let deviceModel: String
    let osVersion: String
    let appVersion: String

    @MainActor static var current: DeviceInfo {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DeviceInfo(
            deviceModel: modelIdentifier(),
            osVersion: UIDevice.current.systemVersion,
            appVersion: "\(short) (\(build))"
        )
    }

    var json: [String: String] {
        [
            "platform": "ios",
            "device_model": deviceModel,
            "os_version": osVersion,
            "app_version": appVersion,
            "sdk_version": devReplySDKVersion,
            "locale": L10n.currentTag,
        ]
    }

    /// e.g. "iPhone16,1". The simulator reports the Mac's CPU, so use the simulated model instead.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
