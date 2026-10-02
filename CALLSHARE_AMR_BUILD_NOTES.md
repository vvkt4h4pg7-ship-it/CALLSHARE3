# CALLSHARE AMR Audio Integration

This package keeps the existing Xcode project structure and uses the supplied OpenCORE AMR-NB sources as an iOS-compatible static library in the GitHub Actions build.

## Verified BLE audio boundary

Historical working Android/K7 traffic supplied with the project shows channel-3 audio frames in this exact shape:

- C0-delimited frame
- channel = 3
- AMR-NB payload including the one-byte ToC header
- ordinary speech frame length varies by AMR mode (for example 14 bytes for FT=1)
- phone -> device uses characteristic 5CBA with write-without-response
- device -> phone uses characteristic 5CB8 notifications

The iOS VoiceEngine therefore uses:

`microphone -> PCM 8 kHz mono -> AMR-NB -> channel-3 BLE frame`

and:

`channel-3 BLE frame -> AMR-NB -> PCM 8 kHz mono -> playback`

## AMR mode

The encoder starts in mode 1 and the decoder learns the incoming mode from the received AMR ToC byte. The previous documentation that called MR122/mode 7 the fixed encoder mode was incorrect and has been removed.
