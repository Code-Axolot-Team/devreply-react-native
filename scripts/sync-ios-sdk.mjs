// Copies the iOS SDK sources (../swift/Sources/DevReply) into ios/DevReplySDK, so the pod compiles them
// with the app. Runs on install in this repo and before publishing; the published package carries the copy.
import { cpSync, existsSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const from = join(root, '..', 'swift', 'Sources', 'DevReply')
const to = join(root, 'ios', 'DevReplySDK')
if (!existsSync(from)) {
  // Published package: the copy is already there.
  if (!existsSync(to)) throw new Error('ios/DevReplySDK is missing')
  process.exit(0)
}
rmSync(to, { recursive: true, force: true })
cpSync(from, to, { recursive: true })
console.log('ios/DevReplySDK ← sdk/swift/Sources/DevReply')
