# CALLSHARE iOS — Call Session / AMR Latency Fix R1

## What was actually wrong in the supplied project

### 1. The iOS source was out of sync with its own R3 documentation
`README_R3_AMR_RX_QUEUE.md` describes a bounded AMR RX queue, but the live `J7Bridge/VoiceEngine.swift` in the supplied project had already lost that queue and was dropping every packet received while `VoiceEngine` was stopped.

That creates the exact race seen during CallKit activation:

`K7 VOICE_OPEN -> AMR packets arrive -> CallKit audio not active yet -> VoiceEngine stopped -> packets dropped`

R1 restores a bounded compressed-AMR queue and adds a second bounded work queue so the system itself cannot accumulate thousands of GCD blocks when decode temporarily falls behind.

### 2. The old call could remain in a non-IDLE state
`AppModel.handleIncoming()` accepted a new incoming call only when `callStatus == IDLE || callStatus == ENDED`.

The old end paths left the long-lived state at `ENDED`. More importantly, any lifecycle race that left `RINGING`, `ACTIVE`, or `DIALING` behind could cause a real new `0x0A` incoming event to be ignored.

R1 makes teardown idempotent and returns the published call state to `IDLE` after the session is fully cleaned.

### 3. CallKit had an independent stale-call lock
`CallKitManager.reportIncoming()` refused a new call whenever `currentUUID != nil`.

A late/stale CallKit transaction could therefore block a perfectly valid second incoming call even while BLE remained connected.

R1 adds:

- explicit `prepareForNewCall()` bookkeeping reset,
- UUID matching for Start/Answer/End CallKit actions,
- safe handling of late `reportNewIncomingCall` completion callbacks,
- safe handling of late outgoing transaction completion,
- answer acknowledgement latching for the rare `K7 0x05` / `CXAnswerCallAction` ordering race.

### 4. Call teardown was duplicated
The previous `CXEndCallAction` delegate called `AppModel.onEnd`, then also called `onAudioDeactivated`. `AppModel.endFromCallKit()` already stopped VoiceEngine, so the same call could execute audio teardown twice.

The old remote-end path also stopped VoiceEngine in AppModel and then CallKitManager performed another audio deactivation callback.

R1 has one authoritative AppModel teardown path. CallKitManager only maintains CallKit state.

### 5. Voice TX audio could survive a call boundary
The BLE audio TX queue was 100 frames, which is about 2 seconds at 20 ms/frame, and it was not cleared immediately from every end path.

R1 changes the live-call queue cap to 25 frames (~500 ms) and clears the audio backlog at every call boundary without disconnecting GATT.

### 6. Playback could accumulate an old tail
The previous VoiceEngine scheduled decoded PCM buffers with no bound on how much audio could already be queued in the player node.

R1 tracks scheduled playback buffers and resets the player backlog once it exceeds 10 frames (~200 ms). The newest speech is kept instead of allowing a burst to become seconds of delayed audio.

### 7. VoiceEngine was not fully reset at call boundaries
The previous `stop()` stopped the engine and reset the player node but did not call `AVAudioEngine.reset()`.

R1 resets the audio graph at call start/end and after stop. This clears node processing state between calls while keeping the player graph reusable.

## The ~3000 Android "AMR DECODE FAILED" lines

The supplied Android diagnostic trace contains 2,966 occurrences of the text `AMR DECODE FAILED`.

The repeated pattern is:

`AUDIO FRAME len=14`

followed by:

`AMR DECODE FAILED len=14 ret=0`

The same trace shows valid-looking channel-3 AMR frames whose ToC byte corresponds to an AMR-NB FT1 frame, and the frame length is 14 bytes including ToC.

The important point for this iOS revision is that the iOS OpenCORE ABI used in `VoiceEngine.swift` declares `Decoder_Interface_Decode` as a `void` function and does not use a fake positive sample-count return value as a success test. Therefore the Android-side `ret=0` logging problem is not copied into iOS.

The Android trace also contains separate `AudioRecord`/R4 probe permission failures. Those belong to the diagnostic/probing path and are not evidence that the working GATT channel-3 AMR transport is absent.

## New iOS audio buffering model

```text
CoreBluetooth main queue
        |
        v
   bounded RX work queue (20 frames / 400 ms)
        |
        v
  dedicated AMR RX serial worker
        |
        +--> if CallKit audio is not running:
        |        bounded pending queue (25 frames / 500 ms)
        |
        v
      AMR decode
        |
        v
 bounded AVAudioPlayerNode scheduled tail (10 frames / 200 ms)
        |
        v
     speaker output
```

There is deliberately no unbounded audio queue in the live iOS path.

## New call lifecycle

```text
IDLE
  |
  +--> K7 0x0A --> SESSION BEGIN --> RINGING
  |                         |
  |                         +--> CallKit Incoming
  |                                   |
  |                                   +--> Answer
  |                                           |
  |                                           +--> K7 0x05
  |                                           +--> ACTIVE
  |                                           +--> K7 0x0F
  |                                           +--> CallKit audio ACT
  |                                           +--> VoiceEngine.start
  |
  +--> outgoing CallKit Start --> SESSION BEGIN --> DIALING

ACTIVE/RINGING/DIALING
  |
  +--> local end or K7 0x0B
              |
              +--> VOICE_CLOSE
              +--> clear BLE audio TX backlog
              +--> stop/reset VoiceEngine
              +--> invalidate RX session generation
              +--> write history once
              +--> clear CallKit bookkeeping
              +--> IDLE
```

## Expected clean diagnostic sequence

Incoming call:

1. `[CALL] SESSION BEGIN #N INCOMING ...`
2. CallKit incoming UI reported
3. `[CALLKIT] ANSWER -> K7 05`
4. `[CALL] ANSWER EVENT / ACTIVE`
5. `[VOICE] OPEN EVENT`
6. `[CALLKIT] audio session ACT`
7. `[VOICE] START gate satisfied -> VoiceEngine.start()`
8. `[AMR] RX queue drain count=...` if packets arrived early
9. `[AMR] RX frame #1 ... -> PCM160`

Call end:

1. `[CALL] SESSION END / RESET ... -> IDLE`
2. `[VOICE] CALL SESSION INVALIDATED / RX QUEUE CLEARED`
3. next K7 `0x0A` should produce a new `SESSION BEGIN` rather than `duplicate incoming ignored`

## Validation performed in the working container

- All Swift files in `J7Bridge/` passed Swift frontend syntax parsing with Swift 6.2.1.
- The four changed runtime files (`AppModel.swift`, `CallKitManager.swift`, `VoiceEngine.swift`, `BLEManager.swift`) passed syntax parsing separately.
- Bad escaped interpolation sequences such as `\\(` were removed from the live diagnostic strings.
- A full iOS build was not run because Xcode/iOS SDK is not available in this Linux container.

## Scope

This revision intentionally leaves the stable GATT transport architecture intact. It does not change the J7 GSM HAL/R7 path and does not reopen the GSM PCM device.

The hardware test still needs to confirm actual microphone/speaker samples on the physical iPhone/J7 pair, but the supplied iOS source now has explicit protection against stale CallKit state, RX accumulation, playback accumulation, and cross-call session leakage.
