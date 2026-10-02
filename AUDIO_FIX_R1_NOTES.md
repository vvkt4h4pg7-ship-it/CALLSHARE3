# CALLSHARE Audio Fix R1

## Why this revision exists

The supplied historical Android/J7 logs show that the BLE wire audio is not an abstract VoIP stream. Working traffic is visible on the custom GATT transport as channel-3 AMR-NB frames. The iOS project already had the correct channel-3 framing and an AMR codec, but the live path had several reliability hazards.

## Changes in R1

1. Added an incremental C0-delimited stream parser so a frame split across CoreBluetooth callbacks cannot be lost, while back-to-back frames are handled safely.
2. Added a bounded BLE audio transmit queue with CoreBluetooth no-response backpressure handling and `peripheralIsReady(toSendWriteWithoutResponse:)`. This replaces blind `writeValue(...withoutResponse)` calls.
3. Removed per-audio-frame SwiftUI log publication from the BLE callback. The callback runs on the main queue, so updating the UI log for every audio packet could starve BLE/audio processing.
4. Restricted audio parsing to the 5CB8 notification characteristic and kept 5CB9 flow traffic out of the audio parser.
5. Added explicit speaker routing for the default test path and stricter AVAudioSession error reporting.
6. Marked outgoing CallKit calls as connected when the K7 answer event is received so CallKit can activate the audio session for the outgoing path.
7. Send `VOICE_CLOSE (0x10)` before hangup when a local CallKit end occurs.

## Verified wire facts used by this revision

- Service: `0783B03E-8535-B5A0-7140-A304D2495CB7`
- RX: `0783B03E-8535-B5A0-7140-A304D2495CB8`
- FLOW: `0783B03E-8535-B5A0-7140-A304D2495CB9`
- TX: `0783B03E-8535-B5A0-7140-A304D2495CBA`
- Voice open: `0x0F`
- Voice close: `0x10`
- Audio channel: `3`
- BLE audio frame: `C0 E3 00 1D 0C ... C0` for a 14-byte AMR frame
- AMR speech frame is delivered with its ToC byte included

## Expected diagnostic milestones

On a successful incoming/outgoing call, look for:

`[CALLKIT] audio session ACT`

`[VOICE] starting; ... rate=...Hz io=...ms`

`[AMR] codec READY encoderMode=1`

`[AMR] TX frame #... len=14 mode=...`

`[BLE] AUDIO TX #... len=19 queue=...`

For receive:

`[J7BRIDGE_DIAG] AUDIO RX #... len=14`

`[AMR] RX frame #... len=14 ... -> PCM160`

`[J7BRIDGE_DIAG] playback scheduled samples=160 ...`

The main-queue log should no longer print every audio notification.

## Validation performed in the working container

Swift frontend syntax parsing passed for the modified Swift sources (`K7Protocol.swift`, `BLEManager.swift`, `VoiceEngine.swift`, `AppModel.swift`, `CallKitManager.swift`). A full iOS `xcodebuild` could not be run because Xcode/iOS SDK is not installed in this container.

## Important scope note

This revision does not pretend that an end-to-end hardware voice call was tested here. It implements the verified BLE audio boundary and removes the most likely live-path stalls in the supplied CALLSHARE project. The next real-device test should capture the diagnostic sequence above and determine whether AMR RX/TX and PCM values are both non-zero.
