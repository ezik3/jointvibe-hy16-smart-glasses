# AI Conversation Pipeline

This document describes the physically-approved fast conversation
architecture at the `hy16-fast-conversation-pre-onboarding-recovery-v1`
baseline, and — deliberately — the history of what was tried and
rejected, so nobody (human or AI) picking this project back up mistakes
a later, worse-performing experiment for the good version.

## Core proven behavior

- **Fixed 900ms silence endpoint** (`JVSpeechTestController.silenceEndpointDurationMs`).
  Apple's `SFSpeechAudioBufferRecognitionRequest` has no built-in
  end-of-speech detection, so this project implements its own via simple
  RMS energy detection on the decoded PCM buffers: after real speech is
  detected (a `minimumSpeechDurationBeforeAutoStopMs` gate prevents a
  single blip or ambient noise from arming this), 900ms of continuous
  silence ends the turn.
- **Continuous listening / automatic next-turn listening.** ASR
  restarts immediately after every final transcript — *before* the
  LLM/TTS/playback for that turn even resolves — so the microphone is
  live for the AI's entire "thinking" and "speaking" duration. No button
  press is needed between turns.
- **`openai/gpt-5-nano`, `reasoning.effort=minimal`.** GPT-5-family
  models otherwise emit an unbounded amount of invisible "reasoning"
  content before any visible answer, adding highly variable latency
  (measured 3.8-11.4s without this setting). Setting
  `reasoning.effort=minimal` brought this down to a consistent
  1.4-1.75s in repeated live testing.
- **Direct Kokoro TTS**, not a general-purpose local voice-app wrapper —
  see `docs/ARCHITECTURE.md` for why, and `direct-kokoro-service/` for
  the implementation. Warm synthesis: ~0.2-0.4s.
- **Barge-in.** Two independent heuristics — an interim ASR transcript
  that doesn't look like an echo of the AI's own current speech (too
  short, or a substring of what's being spoken), or sustained
  voice-activity energy outside a short (400ms) echo-protection window —
  trigger an immediate, atomic interruption.
- **LLM/TTS cancellation.** Barge-in calls `.cancel()` on the in-flight
  `URLSessionDataTask` for both the LLM request and the TTS request.
- **`turnGeneration` stale-callback protection.** A monotonically
  incrementing counter, captured by every async completion at issue
  time and compared against the current value before acting — because a
  cancelled `URLSessionDataTask` still invokes its completion handler,
  this is required even with `.cancel()` in place, to stop "Turn 1
  completes after Turn 2 has already started, and Turn 1 suddenly
  speaks."
- **Echo suppression** (two heuristics, both disclosed as experimental
  starting values subject to physical tuning, not proven constants):
  content-comparison (is the interim transcript too short, or a
  substring of what the AI is currently saying?) and a 400ms
  echo-protection window applied only to the faster, riskier
  "sustained voice activity" barge-in trigger.
- **Immediate speaker playback** via `GlassesSpeakerTestController`,
  through the iPhone's normal Bluetooth-audio route (not the BLE `0x0A03`
  downlink — see `docs/HY16_PROTOCOL_NOTES.md`).
- **`aiState` playback-completion fix.** `GlassesSpeakerTestController`
  exposes an `onPlaybackFinished` hook, fired only from the two
  success-completion delegate callbacks (`audioPlayerDidFinishPlaying`/
  `speechSynthesizer(_:didFinish:)`), which resets `JVConversationController.aiState`
  back to `.idle` after a normal, uninterrupted turn. Without this, the
  UI's "AI State" label got stuck on "Speaking" forever after every
  successful turn, and a harmless spurious barge-in log line appeared at
  the start of the next turn.
- **Latency instrumentation.** `JVLatencyTracker`/`JVLatencySession`
  record checkpoint timestamps (`llmRequestSent`, `llmResponseComplete`,
  `ttsRequestSent`, `ttsComplete`, `playbackRequested`, ASR endpoint
  timing, etc.) and print a full `=== JV LATENCY BREAKDOWN ===` summary
  per turn — use this to diagnose any future latency regression rather
  than guessing.

## History — what was tried and rejected, in order

Documenting this explicitly so a later developer/AI doesn't assume a
later commit represents an improvement just because it's later.

1. **Adaptive/intelligent endpointing** (COMPLETE/UNCERTAIN/LIKELY_INCOMPLETE
   transcript classification, tiered 900/1600/3500ms silence deadlines
   depending on how "finished" an utterance sounded) was implemented and
   physically tested. **Rejected** — the user explicitly disliked how it
   felt ("I DO NOT like how it feels... it's fucking outstanding [the
   fixed 900ms version]. I love how quick it is... That is the behaviour
   I want back"). Reverted via exact filesystem snapshot restore, not
   reconstruction. The fixed 900ms endpoint is the proven, wanted
   behavior — do not reintroduce adaptive/tiered endpointing without new
   explicit approval and a new physical test.

2. **AI identity/onboarding** (a first-time conversational setup asking
   the wearer's preferred name and the assistant's preferred name,
   persisted locally via `UserDefaults`) was built *after* the fast
   conversation baseline above, in two passes: first a local
   phrase-matching implementation (rejected — too brittle on natural
   speech, e.g. "Call me Esi" or "My name's Esikelitonga but everyone
   calls me Esi" produced nonsensical confirmation loops), then a hybrid
   architecture (deterministic state machine + GPT-5-nano structured
   interpretation per utterance). During physical testing of the hybrid
   version, the direct Kokoro service became unreachable (a stale LAN IP
   in `Secrets.plist` from a Mac DHCP address change — see
   `docs/ARCHITECTURE.md`'s LAN IP warning), producing 30+ second delays
   and a fallback to the on-device Apple TTS voice. **The onboarding
   feature itself was never physically validated as a net improvement**
   before this environment issue forced a full rollback.

3. **Therefore: `hy16-fast-conversation-pre-onboarding-recovery-v1` is
   the canonical conversation baseline** — restored, byte-for-byte,
   from the exact filesystem snapshot captured immediately before the
   onboarding work began. It contains everything in "Core proven
   behavior" above and deliberately contains **no** identity/onboarding
   layer (no `AIIdentity.swift`, `AIProfileStore.swift`,
   `JVOnboardingController.swift`, and no `UserDefaults` usage anywhere
   in the project). If AI identity/onboarding is revisited in the
   future, treat it as a new experiment to design, implement, and
   physically re-validate from this baseline — not as something to
   resume from a later, unvalidated commit.
