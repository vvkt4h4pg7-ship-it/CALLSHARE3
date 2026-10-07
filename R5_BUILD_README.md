# CALLSHARE R5 build

This package is a surgical revision of the supplied CALLSHARE iOS project.

Modified source files:

- `J7Bridge/AppModel.swift`
- `J7Bridge/VoiceEngine.swift`
- `J7Bridge/CallKitManager.swift`

No Xcode project membership changes are required; the existing project already lists these three Swift files in the target.

Build the project in the same Apple/Xcode environment used for the existing working IPA.

After installing, use the in-app Diagnostic Log and capture one complete failed or successful call. The most important new lines are prefixed `[CALLSHARE_AUDIO_R5]`, `PRESTART`, and `VOICE_OPEN RETRY`.
