# CALLSHARE AMR Audio Integration

This package keeps the original Xcode project file unchanged and builds the supplied
OpenCORE AMR-NB sources as an arm64 iPhoneOS static library in GitHub Actions.

Audio path:
- iPhone microphone -> PCM -> AMR-NB encoder -> BLE
- BLE -> AMR-NB decoder -> PCM 8 kHz -> AVAudioEngine output

The encoder currently uses AMR-NB MR122 (mode 7). The decoder accepts the mode carried
by the received IETF AMR frame header.
