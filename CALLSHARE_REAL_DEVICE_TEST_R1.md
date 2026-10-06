# CALLSHARE iOS R1 — Real Device Test

## Before test

Do not disconnect/re-pair GATT between calls. Start the app once and leave the BLE connection alive.

## Test A — incoming call twice

1. Receive call #1.
2. Answer from the iPhone CallKit UI.
3. Talk for at least 10 seconds both directions.
4. End the call normally.
5. Wait 2 seconds.
6. Receive call #2 without restarting the app.
7. Answer and talk again.
8. Repeat for call #3.

The key success condition is that every call creates a new `[CALL] SESSION BEGIN #N` and every completed call returns to `IDLE` without reconnecting GATT.

## Test B — fast recurrence

End call #1 and immediately place/receive call #2 within about 1 second. This intentionally stresses the old UUID/state race.

Expected: Call #2 still gets a CallKit incoming UI and is not logged as `duplicate incoming ignored`.

## Test C — audio activation race

On an incoming call, answer immediately. It is acceptable for AMR packets to arrive before the CallKit audio session activates.

Expected instead of drops:

`[AMR] RX queued while engine stopped ...`

then:

`[VOICE] START gate satisfied -> VoiceEngine.start()`

and:

`[AMR] RX queue drain count=...`

## Test D — latency / burst

Keep the call active while producing continuous speech for at least 30 seconds.

Watch for:

- `[BLE] AUDIO TX backpressure`
- `[BLE] AUDIO TX queue overflow`
- `[AMR] RX work queue overflow`
- `[AUDIO] playback backlog reset`

A rare backlog-reset message is protective; repeated messages indicate that the physical link or codec is falling behind.

## Test E — end contamination

After ending a call, stay silent for 3 seconds and then start another call.

The second call must not begin by playing old audio from the previous call.

## Useful evidence to capture

For one failing run, export the iPhone log from the first `SESSION BEGIN` through the next `SESSION BEGIN` and include all `[CALL]`, `[CALLKIT]`, `[VOICE]`, `[AMR]` and `[BLE] AUDIO` lines. The new R1 logs are deliberately rate-limited so the important state transitions remain visible.
