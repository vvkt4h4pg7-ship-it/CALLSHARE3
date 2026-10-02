# J7Bridge Final — merge/build plan

This project merges the verified BLE/GATT side of J7Bridge with the CallKit/audio-session behavior observed in the supplied CallKit build, using the supplied IKOS K7 Android source as the protocol authority.

## Included now

- IKOS K7 BLE central scan/connect/discovery.
- Exact K7 service/RX/FLOW/TX UUIDs.
- Exact control and channel-3 audio framing/escaping/checksums from the supplied source.
- Incoming GSM event `0x0A` -> iOS CallKit incoming-call UI.
- CallKit Answer -> K7 `0x05`.
- K7 Answer event `0x05` -> CallKit answer fulfillment -> K7 `0x0F` voice-open request.
- K7 voice-open event `0x0F` -> audio start is armed, but only when CallKit has activated the audio session.
- K7 call-end event `0x0B` -> CallKit remote end.
- CallKit End -> K7 `0x04`.
- Outgoing keypad -> CallKit start transaction -> K7 `0x02` with SIM id + UTF-16LE number.
- DTMF pass-through path via K7 `0x03` opcode. The supplied K7 source exposes the opcode/parameter shape but does not document the exact key-value table; the iOS terminal currently sends the ASCII key byte and this remains a wire-test item.
- Contact lookup and contact creation using the iOS Contacts framework.
- Local recents/history with incoming/outgoing/missed call records.
- Optional missed-call local notifications.
- Settings for auto-connect, caller-name resolution, notifications, speaker default and SIM slot.
- K7 diagnostic requests for device check, battery, firmware and IMEI.

## Microphone lifecycle

The final app does not call `VoiceEngine.start()` at app launch or merely because BLE is connected.

The intended state is:

`BLE connected -> microphone OFF`

`K7 0x0A -> CallKit incoming -> microphone OFF`

`user answers -> K7 0x05 -> wait for CallKit audio activation + K7 0x0F`

`both active -> VoiceEngine.start() -> microphone ON`

`call ends / CallKit deactivates -> VoiceEngine.stop() -> microphone OFF`

## Voice path now implemented

The supplied Android source uses AMR-NB. The iOS project now contains an iOS-compatible OpenCORE AMR-NB encoder/decoder wrapper. The audio path is therefore implemented through the verified channel-3 framing: 8 kHz mono PCM -> AMR-NB -> BLE TX, and BLE RX -> AMR-NB -> 8 kHz PCM playback. End-to-end speech still requires a live peer test; this package does not claim that hardware playback has been proven inside the container.

## Outgoing active-call extension

The supplied Android source launches the physical GSM call for K7 `0x02`, and its current `PhoneStateListener` tracks OFFHOOK, but it does not emit a BLE event for that outgoing OFFHOOK transition. The optional patch in `K7_OPTIONAL_PATCH/TelephonyBridge_outgoing_active.patch` reuses the already-defined `0x05` active/answer event as a project-level outgoing-active notification, after which the iOS side can send `0x0F` and enter the same voice-open path.

That patch is intentionally separate from the known-good K7 APK so the working incoming-call setup is not disturbed until outgoing is tested.
