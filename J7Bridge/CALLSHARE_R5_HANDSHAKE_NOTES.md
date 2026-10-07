# CALLSHARE R5 — Hybrid GSM Voice Handshake

## Why R5 exists

The supplied iPhone diagnostic screenshots show a real CallKit activation, a running VoiceEngine, and non-empty microphone AMR TX frames. The critical failure is that the app currently waits for local CallKit audio activation and VoiceEngine startup before sending `VOICE_OPEN` to K7. That makes the remote GSM voice start depend on the iPhone audio startup race.

R5 changes this to a hybrid sequence: K7 voice opens immediately after the `0x05` answer event, while the iPhone local audio engine still waits for CallKit `didActivate`.

## New startup sequence

`CallKit ANSWER -> K7 0x05 -> iPhone receives 0x05 -> immediately send K7 0x0F -> CallKit didActivate -> VoiceEngine.start() -> flush up to 5 early AMR frames -> live RX/TX`

`remoteVoiceOpen` is treated only as an acknowledgement/state signal. It is never a local start prerequisite.

## R5 safety mechanisms

- Up to 5 AMR frames (~100 ms) are buffered before the local audio graph is running.
- Buffered startup frames are flushed in wire order after `AVAudioEngine` starts.
- K7 `VOICE_OPEN` is retried at approximately 300 ms and 700 ms when no ACK arrives, for a maximum of two retries.
- Retry work is cancelled as soon as the K7 `VOICE_OPEN` event is received.
- The iPhone preferred I/O buffer target is reduced from 20 ms to 10 ms. The actual runtime value remains controlled by the system/CallKit and is logged.
- Microphone AMR delivery to the CoreBluetooth/main queue uses a single-slot coalescing handoff. Under temporary main-queue pressure, the newest frame replaces an older pending frame instead of creating delayed speech.
- Existing C0 framing, channel-3 AMR-NB, 5CB8 RX, 5CB9 FLOW, 5CBA TX, CallKit UUID/session cleanup, and playback queue limits are unchanged.

## Diagnostic signals to capture

For each real call, capture this sequence from the iPhone Diagnostic Log:

- `[CALLKIT] ANSWER action -> BLE 05`
- `[CALL] ANSWER EVENT / ACTIVE`
- `[VOICE] VOICE_OPEN -> K7 reason=K7 ANSWER / EARLY`
- `[CALLKIT] audio session ACT`
- `[CALLSHARE_AUDIO_R5] didActivate uptime=...`
- `[VOICE] AUDIO READY -> VoiceEngine.start()`
- `[VOICE] ENGINE RUNNING startCost=...ms`
- `[AMR] PRESTART buffered ...` (only when K7 starts early)
- `[AMR] PRESTART flush frames=...`
- `[J7BRIDGE_DIAG] BLE RX 5CB8 value #...`
- `[J7BRIDGE_DIAG] AUDIO RX #...`
- `[AMR] RX frame #... -> PCM160`
- `[AMR] TX frame #...`

A healthy receive path must eventually show `AUDIO RX` / `AMR RX frame`. A healthy uplink must show `AMR TX frame` and BLE audio TX.

## Real-device test

1. Leave the same BLE connection in place.
2. Make one incoming GSM call.
3. Answer from the iPhone CallKit UI.
4. Wait 2 seconds and speak in both directions.
5. End the call from the iPhone.
6. Repeat for a second and third call without restarting Bluetooth.

Do not change the Android/J7 audio layer for this test. The purpose is to isolate iOS startup timing.

## Validation in this container

All top-level Swift sources pass `swiftc -parse` syntax validation. A full iOS build cannot be executed here because an Apple iOS SDK/Xcode environment is not available.
