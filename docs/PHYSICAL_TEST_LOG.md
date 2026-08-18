# Physical Test Log

A running record of end-to-end physical test results against real
hardware. Unlike the other docs in this repository, entries here are
dated observations, not living reference material — don't edit past
entries, append new ones.

---

## 2026-08-18 — PHYSICAL PASS: real iPhone + real HY-16 + AI conversation + Kokoro + glasses playback

**Tag:** `hy16-fast-conversation-physical-pass-v1`

**Result:** Full end-to-end conversational loop physically confirmed on
a real iPhone connected to a real HY-16 unit: microphone → BLE → ASR →
GPT-5-nano → direct Kokoro TTS → playback through the HY-16's own
speaker. This is the first tag in this repository's history that
specifically certifies a live physical test on real hardware end-to-end
(the earlier `hy16-fast-conversation-pre-onboarding-recovery-v1` and
`hy16-complete-disaster-recovery-v1` tags certify *source state*,
recovered/backed up correctly — not a fresh physical confirmation on
their own).

Verified directly from source before this entry was written (not
assumed):

- Fixed 900ms silence endpoint — `JVSpeechTestController.silenceEndpointDurationMs`.
- `openai/gpt-5-nano` via OpenRouter, `reasoning.effort=minimal` — `Secrets.plist` / `OpenRouterAIService.swift`.
- Direct Kokoro TTS, voice `af_heart`, model `kokoro-direct`, served by `direct-kokoro-service/server.py` — `Secrets.plist`.
- Continuous conversation / automatic re-listening — `JVConversationController.beginNewListeningSession()`, called immediately after every final transcript and from `startContinuousConversation()`.
- Barge-in / interrupt handling — `JVConversationController.handleInterimTranscript`, `handleSustainedVoiceDetected`, `interruptCurrentResponse`, `GlassesSpeakerTestController.stopImmediately()`.
- HY-16 glasses speaker playback — `GlassesSpeakerTestController.playSynthesizedAudio(_:)` / `speak(_:)`.
- No identity/onboarding layer present (`grep -rl "UserDefaults"` across the whole project returns nothing).

### Failure mode discovered and resolved during this test cycle

Before the passing test, the app failed to reach direct Kokoro at all:
the iPhone's console showed
`NSURLErrorDomain Code=-1004 "Could not connect to the server"` for
requests to the configured `VoiceStudioBaseURL`.

**Root cause:** the Mac's DHCP-assigned LAN IP had changed since
`Secrets.plist` was last configured — `VoiceStudioBaseURL` still pointed
at a now-dead address. `direct-kokoro-service` itself was healthy the
entire time (same long-running process, listening correctly on
`*:3902`, verified locally reachable and fast) — the app's AI/BLE/audio
code was never the problem.

**Fix:** updated `VoiceStudioBaseURL` in the local, git-ignored
`HY16Probe/Secrets.plist` to the Mac's then-current LAN IP,
`192.168.0.44`. This is a local configuration value only — it is not
committed to this repository, and `192.168.0.44` should **not** be
assumed correct in any future session; it was simply the correct value
at the moment of this specific test. See "Standing lesson" below.

### Standing lesson: a changing Mac DHCP address can break local Kokoro connectivity even when the AI conversation code itself is completely healthy

This is now the **second** time in this project's history that a stale
LAN IP in `Secrets.plist` produced a connectivity failure that looked
like it could be an AI/TTS/code regression but was not:

1. First occurrence: `VoiceStudioBaseURL` pointed at `192.168.0.139`
   after the Mac's IP had changed to `192.168.1.218` — requests timed
   out (`NSURLErrorDomain -1001`) after ~30+ seconds, and the app fell
   back to the much lower-quality on-device Apple TTS voice, which
   looked like a TTS quality regression rather than a network issue.
2. This occurrence: `VoiceStudioBaseURL` pointed at the now-stale
   `192.168.1.218` after the Mac's IP had changed again to
   `192.168.0.44` — requests failed immediately
   (`NSURLErrorDomain -1004`, "Could not connect to the server").

**Before assuming an AI conversation, Kokoro, or BLE code regression
when direct Kokoro appears to stop working, always re-verify the Mac's
current LAN IP (`ipconfig getifaddr en0`) against
`Secrets.plist`'s `VoiceStudioBaseURL` first.** See
`docs/ARCHITECTURE.md`'s "LAN IP addresses are not permanent
configuration" section and `docs/RECOVERY.md` step 6 for the standing
guidance this incident reinforces.
