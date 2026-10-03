# CALLSHARE iOS R3 — AMR RX Queue / CallKit Audio Activation

## Purpose

R3 targets the failure observed in the 2026-10-03 diagnostic trace:

- `VOICE OPEN EVENT`
- `[AMR] RECEIVE ENTRY len=14`
- `[AMR] RX dropped while voice engine stopped`

The BLE AMR packet was therefore arriving before CallKit audio activation had allowed
`VoiceEngine.start()` to run.

## Changes

### VoiceEngine.swift
- Replaced the silent `guard isRunning` drop with a bounded compressed-AMR RX queue.
- Queue capacity: 25 AMR frames (~500 ms at 20 ms/frame).
- If the queue is full, the oldest frame is discarded.
- After `AVAudioEngine.start()` succeeds, the engine is marked `STARTED`.
- Queued AMR frames are then decoded and scheduled to the playback node.
- Added diagnostic status lines:
  - `[AMR] RX queued while engine stopped ...`
  - `[AMR] RX queue drain count=...`
  - `[AMR] RX frame #... -> PCM160`
  - `STARTED / mic ...`
- Stop clears any queued compressed frames and reports the count.

### AppModel.swift
`maybeStartVoice()` now logs exactly which gate is waiting:
- `WAIT call not ACTIVE`
- `WAIT remote VOICE_OPEN`
- `WAIT CallKit audio activation`
- `START gate satisfied -> VoiceEngine.start()`

## Expected test signature

On an incoming answered call, the useful sequence is:

1. `[CALL] ANSWER EVENT / ACTIVE`
2. `[VOICE] OPEN EVENT`
3. If CallKit is not active yet:
   `[VOICE] WAIT CallKit audio activation`
4. AMR arrives:
   `[AMR] RX queued while engine stopped count=1 len=14`
5. CallKit activates:
   `[VOICE] START gate satisfied -> VoiceEngine.start()`
6. Audio engine:
   `STARTED / ...`
7. Queue:
   `[AMR] RX queue drain count=...`
8. Decode/play:
   `[AMR] RX frame #1 len=14 -> PCM160`

This R3 does not change the J7 GSM audio path. The next diagnostic target remains
the J7 `OFFHOOK` / GSM voice-session / PCM path once iOS is confirmed to accept and
play the incoming AMR frames.
