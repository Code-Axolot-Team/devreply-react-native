import Foundation

extension Bundle {
    /// DevReply's fonts, icons and privacy manifest. Swift Package Manager builds them into
    /// `Bundle.module`; CocoaPods (the React Native and Flutter packages) into a `DevReply.bundle`
    /// inside the framework or app.
    static let devReply: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        let host = Bundle(for: BundleToken.self)
        for candidate in [host, .main] {
            if let url = candidate.url(forResource: "DevReply", withExtension: "bundle"), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return host
        #endif
    }()
}

private final class BundleToken {}
