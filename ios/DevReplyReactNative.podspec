require 'json'
package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The DevReply iOS SDK (SwiftUI) compiled into this pod from DevReplySDK/ (copied from the iOS SDK by
# scripts/sync-ios-sdk.mjs), plus the React Native bridge. No CocoaPods trunk dependency.
Pod::Spec.new do |s|
  s.name           = 'DevReplyReactNative'
  s.version        = package['version']
  s.summary        = package['description']
  s.homepage       = 'https://github.com/Code-Axolot-Team/devreply-react-native'
  s.license        = { type: 'MIT' }
  s.author         = 'Code Axolot'
  s.platforms      = { ios: '17.0' }
  s.source         = { git: 'https://github.com/Code-Axolot-Team/devreply-react-native.git', tag: s.version.to_s }
  s.static_framework = true
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = 'DevReplyModule.swift', 'DevReplySDK/**/*.swift'
  s.resource_bundles = {
    'DevReply' => ['DevReplySDK/Resources/Fonts', 'DevReplySDK/Resources/Icons.xcassets', 'DevReplySDK/PrivacyInfo.xcprivacy']
  }
end
