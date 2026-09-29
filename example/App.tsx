import DevReply from '@devreply/react-native'
import { useEffect, useState } from 'react'
import { Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native'

// Your app's public keys from the DevReply dashboard (Settings → Platforms). Safe to ship.
// Set them in example/.env: EXPO_PUBLIC_DEVREPLY_IOS_KEY=pk_… and EXPO_PUBLIC_DEVREPLY_ANDROID_KEY=pk_…
DevReply.configure({
  ios: process.env.EXPO_PUBLIC_DEVREPLY_IOS_KEY ?? 'pk_YOUR_IOS_KEY',
  android: process.env.EXPO_PUBLIC_DEVREPLY_ANDROID_KEY ?? 'pk_YOUR_ANDROID_KEY',
})
DevReply.setAttributes({ demo_app: true, framework: 'react-native' })

/** A blank app with one button. It opens DevReply's native chat (SwiftUI on iOS, Compose on Android). */
export default function App() {
  const [unread, setUnread] = useState(0)
  useEffect(() => {
    const sub = DevReply.addUnreadListener(setUnread)
    return () => sub.remove()
  }, [])

  return (
    <SafeAreaView style={styles.page}>
      <View style={styles.body}>
        <Text style={styles.tag}>DEMO APP · REACT NATIVE</Text>
        <Text style={styles.title}>Talk to the developer.</Text>
        <Text style={styles.text}>This is a React Native app with one button. It opens DevReply's native chat.</Text>
        <Text style={styles.text} testID="unread">
          Unread: {unread}
        </Text>
      </View>
      <Pressable testID="openMessenger" accessibilityRole="button" style={styles.button} onPress={() => DevReply.present()}>
        <Text style={styles.buttonText}>Message the developer</Text>
      </Pressable>
      <Pressable testID="reportBug" accessibilityRole="button" style={[styles.button, styles.second]} onPress={() => DevReply.present('bug')}>
        <Text style={styles.buttonText}>Report a bug</Text>
      </Pressable>
    </SafeAreaView>
  )
}

const ink = '#111111'
const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: '#F6EB37' },
  body: { flex: 1, padding: 24, paddingTop: 64, gap: 18 },
  tag: { alignSelf: 'flex-start', backgroundColor: ink, color: '#F6EB37', fontWeight: '700', fontSize: 13, letterSpacing: 1.2, paddingHorizontal: 8, paddingVertical: 4 },
  title: { color: ink, fontSize: 44, fontWeight: '900', lineHeight: 48 },
  text: { color: ink, fontSize: 18, fontWeight: '500', lineHeight: 24 },
  button: { marginHorizontal: 24, marginBottom: 16, height: 62, justifyContent: 'center', paddingHorizontal: 20, backgroundColor: '#FF5FA2', borderWidth: 3, borderColor: ink },
  second: { backgroundColor: '#fff', marginBottom: 32 },
  buttonText: { color: ink, fontSize: 19, fontWeight: '700' },
})
