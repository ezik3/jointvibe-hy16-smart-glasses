# Joint Vibe — HY-16 Smart Glasses Development

This repository is the disaster-recovery archive for Joint Vibe's HY-16
smart-glasses iOS development work: `HY16Probe`, the CoreBluetooth/SwiftUI
probe app that has been used to reverse-engineer and prove out the HY-16's
BLE protocol, audio pipeline, and AI conversation architecture; and
`direct-kokoro-service`, the local text-to-speech service it currently
depends on.

## What is HY16Probe?

An XcodeGen-managed iOS app (`HY16Probe/`, `project.yml`,
`HY16Probe.xcodeproj/`) built incrementally, one physically-verified
capability at a time, against a real HY-16 unit (manufacturer 禾胜成 /
Heshengcheng, BES chipset, "Hyper" branded). It is a test harness, not
the final consumer Joint Vibe product — see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for why that distinction
matters for anything built on top of it later.

## What is direct-kokoro-service?

A small standalone Python HTTP server (`direct-kokoro-service/server.py`)
that keeps an Apple-Silicon MLX build of the Kokoro-82M text-to-speech
model warm in memory and exposes an OpenAI-compatible
`/v1/audio/speech` endpoint on the Mac's LAN. It exists because routing
TTS through a general-purpose local voice-app wrapper added ~1.7-2.1s of
overhead per turn; this service cuts that to roughly 0.2-0.4s warm. See
[`docs/AI_CONVERSATION_PIPELINE.md`](docs/AI_CONVERSATION_PIPELINE.md).

## What is currently physically proven

On real HY-16 hardware, end-to-end and interactively:

- HY-16 microphone → BLE (`0x0A02`/`0x0A03`) → Opus decode → Apple Speech
  recognition → transcript.
- A continuous, hands-free AI conversation loop: transcript → OpenRouter
  (`openai/gpt-5-nano`, `reasoning.effort=minimal`) → reply → direct
  Kokoro TTS → synthesized audio played back through the HY-16 speaker,
  with automatic re-listening between turns, barge-in (the wearer can
  interrupt the AI mid-sentence and it stops immediately), and a fixed
  900ms silence-based end-of-speech endpoint.
- Photo capture, video recording + download/playback, and continuous
  RTSP live preview (see `docs/HY16_PROTOCOL_NOTES.md` for exact commands).

## Known-good physical baseline

**Tag:** `hy16-fast-conversation-physical-pass-v1`

This tag means: **real iPhone + real HY-16 + AI conversation + Kokoro
voice + glasses playback, physically confirmed working, end to end, on
real hardware** — not just a recovered/backed-up source state. See
[`docs/PHYSICAL_TEST_LOG.md`](docs/PHYSICAL_TEST_LOG.md) for the exact
test date, what was verified, and a discovered/resolved failure mode
(a stale Mac LAN IP breaking local Kokoro connectivity) worth knowing
about before you assume a future connectivity issue is a code
regression.

The source at this tag is identical to the earlier
`hy16-fast-conversation-pre-onboarding-recovery-v1` (commit
`8cb4dcf72ab7b65e93639df8ce3ca166c69a47e0`) plus `hy16-complete-disaster-recovery-v1`
— that earlier tag remains the canonical reference point for "the fast
conversation source code, captured immediately *before* a later
AI-identity/onboarding experiment was attempted and then rolled back
after physical testing revealed regressions" (see
[`docs/AI_CONVERSATION_PIPELINE.md`](docs/AI_CONVERSATION_PIPELINE.md)
for that full history — this is deliberately documented so nobody, human
or AI, mistakes a later, worse-performing experiment for the good
version). The physical-pass tag above is the one to trust for "does this
actually work on real hardware," since it's backed by an actual test,
not just source provenance.

If you are picking this project back up after a long gap, or on a new
machine: start from this tag, not from whatever `main` happens to
contain, unless you already know a later commit is also physically
verified.

## Starting a disaster recovery

See [`docs/RECOVERY.md`](docs/RECOVERY.md) for the complete, step-by-step
procedure assuming you are starting from nothing but this GitHub
repository, a new Mac, the physical HY-16 glasses, and your own private
API credentials.

Quick orientation for the other docs:

- [`docs/RECOVERY.md`](docs/RECOVERY.md) — full fresh-Mac rebuild steps.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — what runs where
  (glasses / iPhone / Mac / internet) and why.
- [`docs/HY16_PROTOCOL_NOTES.md`](docs/HY16_PROTOCOL_NOTES.md) — BLE
  UUIDs and protocol commands we have physically proven ourselves,
  clearly separated from what the manufacturer documents but we have not
  yet verified.
- [`docs/AI_CONVERSATION_PIPELINE.md`](docs/AI_CONVERSATION_PIPELINE.md)
  — the conversation architecture in detail, plus the experiments that
  were tried and rejected.
- [`docs/SETUP_MAC.md`](docs/SETUP_MAC.md) — exact developer environment
  requirements (Xcode, Swift packages, Python, etc.).
- [`vendor-reference/README.md`](vendor-reference/README.md) — where the
  manufacturer's own SDK/protocol documents are kept (not in this
  repository — see that file for why).

## What is intentionally NOT in this repository

- `HY16Probe/Secrets.plist` — your real OpenRouter API key and local
  Kokoro service URL. Never committed. Recreate it from
  `HY16Probe/Secrets.plist.example` — see `docs/RECOVERY.md`.
- The manufacturer's BES/HY-16 SDK archives and protocol documents —
  third-party material with unclear redistribution rights. See
  `vendor-reference/README.md`.
- Filesystem snapshot backups accumulated during iterative development —
  superseded by this repository's own git history and tags going forward.
