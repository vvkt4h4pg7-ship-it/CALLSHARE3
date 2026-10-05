CALLSHARE AUDIO ROUTING R1
============================

Purpose:
- Prepare AVAudioSession before CallKit activation.
- Do NOT call setActive(true) from the app.
- Log CallKit didActivate, route, sample rate, channels, IO buffer.
- Start AVAudioEngine only after didActivate reaches AppModel -> maybeStartVoice().
- Keep existing IKOS Channel 3 -> AMR-NB -> PCM160 -> AVAudioPlayerNode path unchanged.

Files changed:
- CallKitManager.swift
- AppModel.swift
- VoiceEngine.swift

Expected log sequence:
[CALLSHARE_AUDIO_R1] PREPARE before CallKit activation
[CALLSHARE_AUDIO_R1] prepareForCallAudio ENTER
[CALLSHARE_AUDIO_R1] PREPARED ...
[CALLSHARE_AUDIO_R1] didActivate CALLED
[CALLSHARE_AUDIO_R1] session category=...
[CALLSHARE_AUDIO_R1] session mode=...
[CALLSHARE_AUDIO_R1] sampleRate=...
[CALLSHARE_AUDIO_R1] inputChannels=...
[CALLSHARE_AUDIO_R1] outputChannels=...
[CALLSHARE_AUDIO_R1] route IN[...] OUT[...]
[CALLSHARE_AUDIO_R1] VoiceEngine.start ...
[CALLSHARE_AUDIO_R1] engine.start SUCCESS isRunning=true
[CALLSHARE_AUDIO_R1] playerNode.play isPlaying=true
...
[J7BRIDGE_DIAG] BLE AUDIO RX
[AMR] PCM CHECK ...
[CALLSHARE_AUDIO_R1] playback scheduled ...

Important:
- This is an iOS-only routing/diagnostic patch.
- IKOS/J7 GATT wire format is not changed.
- AMR decoder is not changed.
- No AVAudioSession.setActive(true) is introduced.
