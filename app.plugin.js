// Expo config plugin: DevReply needs iOS 17 and Android 8 (API 26), and the Android SDK comes from
// JitPack. Add "@devreply/react-native" to "plugins" in app.json, then prebuild. Bare React Native apps
// don't use this file (see the README).
// Expo comes from the app (this package doesn't depend on it), so resolve it from the project first.
const { createRunOncePlugin, withGradleProperties, withPodfileProperties, withProjectBuildGradle, withXcodeProject } = require(
  require.resolve('expo/config-plugins', { paths: [process.cwd(), __dirname] }),
)

const pkg = require('./package.json')

function withDevReply(config) {
  config = withPodfileProperties(config, (c) => {
    const current = parseFloat(c.modResults['ios.deploymentTarget'] ?? '0')
    if (!(current >= 17)) c.modResults['ios.deploymentTarget'] = '17.0'
    return c
  })
  // The app target too, not only the pods: the app links DevReply's code, built for iOS 17.
  config = withXcodeProject(config, (c) => {
    const configs = c.modResults.pbxXCBuildConfigurationSection()
    for (const key of Object.keys(configs)) {
      const settings = configs[key].buildSettings
      if (settings && settings.IPHONEOS_DEPLOYMENT_TARGET && !(parseFloat(String(settings.IPHONEOS_DEPLOYMENT_TARGET).replace(/"/g, '')) >= 17)) {
        settings.IPHONEOS_DEPLOYMENT_TARGET = '17.0'
      }
    }
    return c
  })
  config = withGradleProperties(config, (c) => {
    const item = c.modResults.find((p) => p.type === 'property' && p.key === 'android.minSdkVersion')
    if (!item) c.modResults.push({ type: 'property', key: 'android.minSdkVersion', value: '26' })
    else if (!(parseInt(item.value, 10) >= 26)) item.value = '26'
    return c
  })
  config = withProjectBuildGradle(config, (c) => {
    if (!c.modResults.contents.includes('jitpack.io')) {
      c.modResults.contents = c.modResults.contents.replace(
        /allprojects\s*\{\s*repositories\s*\{/,
        (m) => `${m}\n    maven { url 'https://jitpack.io' }`,
      )
    }
    return c
  })
  return config
}

module.exports = createRunOncePlugin(withDevReply, pkg.name, pkg.version)
