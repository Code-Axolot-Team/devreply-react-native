require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# The DevReply iOS SDK (SwiftUI) compiled into this pod from ios/DevReplySDK/ (copied from the iOS SDK by
# scripts/sync-ios-sdk.mjs), plus the React Native bridge (a TurboModule). No CocoaPods trunk dependency.
Pod::Spec.new do |s|
  s.name           = 'DevReplyReactNative'
  s.version        = package['version']
  s.summary        = package['description']
  s.homepage       = 'https://github.com/Code-Axolot-Team/devreply-react-native'
  s.license        = { type: 'MIT' }
  s.author         = 'Code Axolot'
  s.platforms      = { ios: '17.0' }
  s.source         = { git: 'https://github.com/Code-Axolot-Team/devreply-react-native.git', tag: s.version.to_s }
  s.swift_version  = '5.9'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = 'ios/*.{h,mm,swift}', 'ios/DevReplySDK/**/*.swift'
  # The bridge's header uses C++: keep it out of the module Swift sees.
  s.private_header_files = 'ios/*.h'
  s.resource_bundles = {
    'DevReply' => ['ios/DevReplySDK/Resources/Fonts', 'ios/DevReplySDK/Resources/Icons.xcassets', 'ios/DevReplySDK/PrivacyInfo.xcprivacy']
  }

  install_modules_dependencies(s)
end
