# CALLSHARE R4 — Audio Lifecycle / Latency Surgery

## Scope
Only the three supplied iOS files were changed:
- AppModel.swift
- VoiceEngine.swift
- CallKitManager.swift

BLEManager/GATT transport was intentionally not changed.

## What was found in R3
1. The `pendingRXFrames` queue is bounded to 25 frames (500 ms) and is NEVER replayed. `start()` explicitly flushes it. Therefore the claim that this queue can create 10–15 seconds of replay latency is not supported by the R3 source.
2. A more plausible iOS-side latency hazard exists in the microphone TX path: every 20 ms AMR frame was dispatched separately to `DispatchQueue.main.async`. If the main queue is busy, hundreds of closures can accumulate and later deliver stale microphone speech.
3. `voiceOpenRequested` was used as a proxy for local engine state. After a transient CallKit deactivation/re-activation, that flag can remain true while the local audio graph is no longer running, preventing a restart.
4. R3 only configured `.defaultToSpeaker` before activation; the explicit `overrideOutputAudioPort` path was only used when `isRunning` was already true. The first live call therefore did not always get an explicit post-activation speaker route.
5. In `CallKitManager`, a race where K7's ANSWER event arrived before `CXAnswerCallAction` could skip `onPrepareAudio()` entirely.
6. Outgoing `evtAnswer` did not explicitly call `reportOutgoingConnected()`.
7. Call teardown sent HANGUP before VOICE_CLOSE. R4 reverses that order.

## R4 changes
- Pre-start RX is drop-only; no replay queue.
- AMR TX uses a latest-frame coalescer: at most one pending frame is scheduled onto the main queue, so main-queue stalls cannot accumulate seconds of stale mic audio.
- Local engine state is checked independently from remote VOICE_OPEN state.
- Output route is explicitly applied after CallKit activation without deactivating the session.
- Answer race always prepares the CallKit audio session.
- Outgoing answer reports CallKit connected.
- VOICE_CLOSE is sent before HANGUP.
- Call/session generation fencing remains in place.

## Validation
`swiftc -parse` passed for all three R4 Swift sources in the working container.

## What R4 does NOT claim
R4 does not prove that the J7-side GSM uplink injection is functional. The supplied J7 log shows decoded AMR and `trackWrite=160`, but that only proves the J7 app is decoding and writing PCM to its playback path. If the far-end GSM phone still cannot hear after R4, the next investigation should be the J7 uplink injection path, not another iOS queue change.
