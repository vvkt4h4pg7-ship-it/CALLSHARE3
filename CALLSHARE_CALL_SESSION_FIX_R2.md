# R3 follow-up

R3 targets the remaining CallKit/AVAudioSession start-order race identified during real-device testing. See `CALLSHARE_AUDIO_SESSION_R3_SURGERY.md`. The GATT and Android transport remain unchanged.

# CALLSHARE iOS — Call Session / Audio Lifecycle Fix R2

## Deep analysis result

The main recurring failure is a lifecycle synchronization problem on the iPhone side, not a GATT reconnect problem.

### 1. The ~3000 "AMR decode errors" are not ~3000 unique bad frames

The Android diagnostic log contains 2,966 occurrences of `AMR DECODE FAILED`, while the same trace contains 1,488 `AUDIO FRAME len=14` events. The repeated pattern is:

`AUDIO FRAME len=14` → `AMR DECODE FAILED len=14 ret=0` → `[AUDIO] AMR DECODE FAILED len=14 ret=0`

So the apparent ~3000 errors are approximately two log lines per received AMR frame. The same trace repeatedly reports `STREAM PENDING BYTES=0`, so the visible parser buffer is not growing without bound.

The 14-byte AMR-NB frames also have a normal-looking FT=1 ToC byte (`0x0C`). The Android-side `ret=0` message therefore cannot by itself be treated as proof that every frame is corrupt; that return-value interpretation was already identified as a decoder-API mismatch on Android.

### 2. The old iOS call state could strand the next call

The previous `AppModel.handleIncoming()` accepted only `IDLE` or `ENDED`, then changed the state to `RINGING`. If a CallKit report failed, or an end/reset callback arrived in an unexpected order, the app could remain in a non-IDLE state. A later real GSM ring was then ignored as a duplicate/stale incoming call.

R2 centralizes teardown and returns the app to `IDLE` on every terminal path.

### 3. CallKit had a second independent stale-call lock

`CallKitManager` kept its own `currentUUID` and `answerAction`. An old UUID could block a later `reportNewIncomingCall()`. R2 adds `prepareForNewCall()`, stale UUID checks, UUID-safe completion handling, and a provider-reset callback that invalidates the matching CallShare session.

### 4. Incoming CallKit report failure no longer leaves a phantom RINGING session

The incoming-call completion is now tied to the CallShare session ID. If CallKit rejects the report, the session is immediately aborted, BLE audio backlog is cleared, the voice graph is reset, and the J7 call is hung up.

An old asynchronous completion can never clear a newer UUID/session.

### 5. CallKit audio activation race was real

CallKit can activate the audio session before the K7 `0x05` answer event reaches the AppModel. The old code ignored audio activation unless state was already `ACTIVE`.

R2 latches `callAudioActive` for any non-IDLE CallShare session. When K7 subsequently moves the call to `ACTIVE`, `maybeStartVoice()` sees the saved activation and starts VoiceEngine.

### 6. Old TX packets could leak across a fast hangup/re-ring

A microphone callback can finish AMR encoding just before a call ends, while its `DispatchQueue.main` BLE callback executes after the next call has already begun. Clearing the BLE queue alone is not sufficient because that queued closure can append an old AMR frame again.

R2 adds a `VoiceEngine` generation fence to the outgoing AMR callback. A packet from call N is dropped on the main queue if the session generation has already moved to call N+1.

### 7. RX decode work no longer runs on the CoreBluetooth main queue

The iPhone now uses a private serial RX worker and two bounded queues:

- CallKit-start gap queue: 25 AMR frames (~500 ms)
- RX decode work queue: 20 AMR frames (~400 ms)

If decoding falls behind, the oldest frames are dropped instead of allowing an unbounded backlog that becomes multi-second delayed speech.

### 8. Playback backlog is bounded too

`AVAudioPlayerNode` scheduled playback is capped at 10 frames (~200 ms). If an abnormal burst pushes it beyond that bound, the old scheduled tail is discarded and the player is restarted from fresh audio.

This intentionally favors live low-latency speech over replaying stale audio.

### 9. AMR codec state is per-call

`beginCallSession()` and `endCallSession()` reset the OpenCORE AMR encoder/decoder state and clear the PCM accumulator. Decoder history and encoder prediction state therefore cannot bleed from one GSM call into the next.

### 10. GATT is intentionally unchanged

The existing CoreBluetooth/GATT connection remains persistent. No disconnect/reconnect or characteristic redesign was introduced for this fix.

## Expected healthy lifecycle

`IDLE`
→ `SESSION BEGIN`
→ `RINGING`
→ CallKit answer
→ `ACTIVE`
→ `VOICE_OPEN`
→ audio activation (either order)
→ `VoiceEngine STARTED`
→ bounded AMR RX/TX
→ `SESSION END / RESET`
→ `IDLE`

The same sequence is designed to repeat for call 2, call 3, call 4, etc. without GATT reconnection.

## Files changed for R2

- `J7Bridge/AppModel.swift`
- `J7Bridge/CallKitManager.swift`
- `J7Bridge/VoiceEngine.swift`
- `J7Bridge/BLEManager.swift`

## Static validation

All Swift source files in `J7Bridge/` pass `swiftc -frontend -parse` in the available Linux toolchain (syntax parsing only). A full iOS `xcodebuild` was not possible in this environment because the Apple Xcode/iOS SDK is unavailable.

## Real-device success criteria

For at least three consecutive incoming calls without restarting the app or reconnecting BLE:

1. Every call reaches CallKit ringing UI.
2. Answer always reaches K7 once.
3. `VOICE_OPEN` and CallKit audio activation may arrive in either order.
4. VoiceEngine starts each time.
5. RX work queue never grows without bound.
6. Playback backlog remains below ~200 ms except during deliberate protective reset.
7. End returns AppModel to `IDLE`.
8. No old-call AMR appears in the next call.
9. GATT stays connected throughout the whole sequence.
