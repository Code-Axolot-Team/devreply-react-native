import DevReply from '@devreply/react-native'
import * as Notifications from 'expo-notifications'
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
  const [account, setAccount] = useState('signed out')
  useEffect(() => {
    const sub = DevReply.addUnreadListener(setUnread)
    return () => sub.remove()
  }, [])

  // Pushes: the app's own library (expo-notifications) owns notifications; DevReply only answers
  // "is this mine?" for a tapped one, and opens its conversation.
  useEffect(() => {
    const opened = (r: Notifications.NotificationResponse) => {
      if (DevReply.handleNotificationOpened(r)) return
      // the app's own notifications
    }
    void Notifications.getLastNotificationResponseAsync().then((r) => r && opened(r))
    const sub = Notifications.addNotificationResponseReceivedListener(opened)
    void Notifications.requestPermissionsAsync()
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
      <View style={styles.row}>
        {['ana', 'ben'].map((id) => (
          <Pressable key={id} testID={`login-${id}`} style={styles.small} onPress={() => { DevReply.login(`demo-${id}`); setAccount(`signed in as ${id}`) }}>
            <Text style={styles.smallText}>Sign in {id}</Text>
          </Pressable>
        ))}
        <Pressable testID="logout" style={styles.small} onPress={() => { DevReply.logout(); setAccount('signed out') }}>
          <Text style={styles.smallText}>Sign out</Text>
        </Pressable>
        <Pressable testID="deleteUser" style={styles.small} onPress={() => void DevReply.deleteUser().then((ok) => setAccount(ok ? 'account deleted' : 'delete failed'))}>
          <Text style={styles.smallText}>Delete</Text>
        </Pressable>
      </View>
      <Text style={[styles.text, styles.account]} testID="account">{account}</Text>
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
  // Signed-in users: DevReply.login / logout / deleteUser.
  row: { flexDirection: 'row', gap: 8, marginHorizontal: 24, marginBottom: 8, flexWrap: 'wrap' },
  small: { borderWidth: 2, borderColor: ink, backgroundColor: '#fff', paddingHorizontal: 10, paddingVertical: 8 },
  smallText: { color: ink, fontSize: 14, fontWeight: '700' },
  account: { marginHorizontal: 24, marginBottom: 12, fontSize: 14 },
})
