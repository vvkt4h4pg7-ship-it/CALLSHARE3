# CALLSHARE iOS — R3 Audio Session Surgery

## Root cause targeted by R3

R2 already bounded AMR RX/TX and playback queues, but its start gate still had a protocol ordering problem:

- `AppModel` waited for both `callAudioActive` and `remoteVoiceOpen`.
- `evtAnswer` sent `VOICE_OPEN` before local CallKit audio activation was guaranteed.
- `remoteVoiceOpen` is the acknowledgement of that request, so using it as a prerequisite for `VoiceEngine.start()` created an avoidable race/circular dependency.
- K7 could therefore begin delivering AMR while the iPhone VoiceEngine was still stopped. R2 retained up to 25 such frames (~500 ms), which is useful for a short gap but can replay stale speech after a longer CallKit activation delay.

## R3 changes

### 1. Audio-first VOICE_OPEN handshake

New order:

`ANSWER -> wait didActivate -> VoiceEngine.start() -> send VOICE_OPEN -> K7 streams live audio`

`remoteVoiceOpen` is now an acknowledgement/state signal, not a prerequisite for the local audio engine to start.

`VoiceEngine.start()` now returns `Bool`, so `VOICE_OPEN` is not sent if the local audio graph fails to start.

### 2. Hard pre-start AMR flush

Any AMR frames accumulated before the audio engine became ready are discarded after successful start instead of being replayed. This favors live speech over stale speech.

The existing bounded RX work queue remains in place as a safety guard.

### 3. Speaker route without CallKit session rebuild

While a call is running, the speaker setting now uses:

`AVAudioSession.overrideOutputAudioPort(.speaker)`

or:

`AVAudioSession.overrideOutputAudioPort(.none)`

instead of calling `setCategory()` again on a live audio session. This avoids rebuilding the PlayAndRecord session merely to change the output route.

### 4. GATT unchanged

No GATT characteristic, reconnect, parser, or transport design was changed.

### 5. J7/HAL/AMR transport unchanged

No Android-side HAL, TinyALSA, AMR transport, or K7 GSM behavior was changed.

## Expected live sequence

`RING -> ANSWER -> didActivate -> VoiceEngine STARTED -> VOICE_OPEN -> live AMR RX/TX`

On a delayed CallKit activation, AMR cannot intentionally be opened by this app before the local audio engine is ready.

## Test focus

1. First incoming call: ring, answer, two-way audio.
2. Second and third calls without BLE reconnect.
3. Verify no multi-second catch-up speech.
4. Verify speaker toggle does not kill microphone.
5. Verify `didActivate` timing versus `VoiceEngine.start`.
6. Verify no stale pre-start AMR is replayed.

Full iOS `xcodebuild` still requires Apple Xcode/iOS SDK; Linux validation here is syntax parsing only.
