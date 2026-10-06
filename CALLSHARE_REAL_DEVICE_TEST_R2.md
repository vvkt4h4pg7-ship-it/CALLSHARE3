# CALLSHARE iOS — Real Device Test R2

## Test A — repeated incoming calls, no GATT reconnect

Keep iPhone and J7 connected once. Make three incoming GSM calls, answer each, speak for 10–20 seconds, then end normally.

Expected key logs per call:

- `[CALL] SESSION BEGIN #N INCOMING`
- `[CALLKIT] INCOMING UI REPORTED UUID=...`
- `[CALLKIT] audio ACT latched state=RINGING` or activation after ACTIVE
- `[CALL] ANSWER EVENT / ACTIVE`
- `[VOICE] OPEN EVENT`
- `[VOICE] START gate satisfied -> VoiceEngine.start()`
- `[VOICE] STARTED ...`
- `[AMR] RX frame #1 ...`
- `[CALL] SESSION END / RESET ... -> IDLE`

The next incoming call must not produce `duplicate/stale incoming ignored`.

## Test B — CallKit audio activation before/after K7 answer event

Repeat incoming answer several times. The order of these two events is allowed to vary:

- CallKit `didActivate`
- K7 `0x05` answer event

Both orders must end in VoiceEngine STARTED without a manual speaker-route change.

## Test C — rapid end/re-ring

End a call and start the next GSM call as soon as practical. Confirm that the new call does not receive an old AMR frame from the previous call.

Look for:

- `[BLE] audio TX backlog cleared frames=...`
- no multi-second RX/playback backlog
- no delayed replay from the previous call

## Test D — backlog protection

During a call, create a temporary BLE/audio burst if reproducible.

Protective messages may appear once:

- `[AMR] RX work queue overflow; dropped oldest frame`
- `[AUDIO] playback backlog reset to preserve low latency`
- `[BLE] AUDIO TX queue overflow; dropped oldest frames`

They must remain bounded events, not a continuously growing queue.

## Test E — CallKit report failure recovery

If CallKit ever rejects an incoming report, the app must immediately reset the CallShare session and return to `IDLE`. A later GSM call must still be able to ring normally.

Expected failure signature:

`[CALLKIT] incoming completion FAILED -> RESET session=N`

followed by:

`[CALL] ABORT / RESET ... -> IDLE`

## Test F — long call / delay check

Speak continuously for at least 30 seconds. Audio should remain near-live. The design intentionally drops old frames when a queue is overloaded instead of preserving them as a seconds-long delayed buffer.

A delay that stays around hundreds of milliseconds or less is consistent with the protective bounds. A growing delay indicates the physical BLE link or codec is still falling behind and should be investigated from the new queue/backpressure counters rather than by adding more buffering.
