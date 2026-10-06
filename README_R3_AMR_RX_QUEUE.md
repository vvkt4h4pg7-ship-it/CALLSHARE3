# CALLSHARE iOS — AMR RX Queue / CallKit Audio Activation

## Purpose

This design prevents AMR packets arriving around CallKit audio activation from being silently lost, while also preventing an overloaded decoder or player from becoming a seconds-long audio-delay buffer.

## Current behavior

### VoiceEngine.swift

- BLE AMR arrival is moved immediately to a private serial RX worker.
- CallKit/audio-engine start gap: 25 compressed AMR frames (~500 ms) are retained.
- RX decode work queue: 20 frames (~400 ms) maximum.
- Oldest frames are dropped on overflow to preserve low latency.
- Playback scheduling is bounded to 10 PCM frames (~200 ms).
- If the player backlog exceeds that limit, old scheduled audio is discarded and fresh audio is used.
- Call session start/end resets the AMR encoder/decoder and PCM accumulator.
- A session-generation fence prevents old queued TX closures from leaking AMR into a new call.
- `stop()` stops the audio graph but keeps the current call session valid so a short CallKit deactivation can be recovered.
- `endCallSession()` permanently invalidates the session and clears all RX work.

### AppModel.swift

- Every call receives a monotonically increasing session ID.
- CallKit incoming report completion is tied to that session.
- CallKit audio activation is latched even if it arrives before K7 answer acknowledgement.
- Terminal call events converge on one idempotent cleanup path.
- Every completed/aborted call returns AppModel to `IDLE`.

### CallKitManager.swift

- Uses the main queue explicitly.
- Clears stale CallKit bookkeeping before a new CallShare call.
- Uses UUID checks for delayed CallKit actions/completions.
- Latches an early K7 answer acknowledgement so `CXAnswerCallAction` cannot remain unfulfilled because of callback ordering.
- Provider reset invalidates the matching CallShare session.
- Transient audio deactivation does not tear down a still-live CallKit session.

## Expected healthy sequence

1. `[CALL] SESSION BEGIN #N INCOMING`
2. CallKit incoming UI is reported.
3. CallKit audio activation and K7 `0x05` may occur in either order.
4. `ACTIVE` + `VOICE_OPEN` + audio activation satisfy the start gate.
5. VoiceEngine starts.
6. AMR RX is decoded off the CoreBluetooth main queue.
7. Playback stays bounded to live/near-live audio.
8. Call end invalidates the session and returns to `IDLE`.
9. The next GSM call starts with clean call state and clean audio queues while GATT remains connected.
