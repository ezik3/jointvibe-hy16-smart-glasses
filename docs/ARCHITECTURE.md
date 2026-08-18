# Architecture

This document describes the architecture as it exists at the
`hy16-fast-conversation-pre-onboarding-recovery-v1` baseline: a physically
proven, single-user, single-device test harness — not the final Joint
Vibe product architecture. That distinction matters; see "Development
vs. production" at the end.

## End-to-end conversation pipeline

```
HY-16 microphone
  → BLE 0x0A02 (mic uplink enable) / 0x0A03 (Opus-encoded audio, DEVICE→APP)
  → iPhone: BLEScanner (CoreBluetooth) → AudioCaptureController (Opus decode, swift-opus)
  → JVSpeechTestController (Apple SFSpeechRecognizer, custom RMS-based VAD, fixed 900ms
    silence endpoint - Apple's own recognition API has no built-in endpointing)
  → JVConversationController (single orchestration point: turn sequencing, barge-in,
    turnGeneration stale-callback protection, continuous re-listening)
  → OpenRouterAIService (HTTPS POST to openrouter.ai, model openai/gpt-5-nano,
    reasoning.effort=minimal)
  → VoiceStudioTTSService (HTTPS POST to the Mac's direct-kokoro-service, port 3902,
    OpenAI-compatible /v1/audio/speech)
  → GlassesSpeakerTestController (AVAudioPlayer, AVAudioSession .playback/.default)
  → HY-16 speaker, over the normal iOS Bluetooth-audio route (NOT the BLE 0x0A03
    downlink - that path was built and tested but is not what's used for AI replies;
    see docs/HY16_PROTOCOL_NOTES.md)
```

## What runs where

| Component | Runs on | Notes |
|---|---|---|
| BLE transport, Opus decode, ASR, VAD, conversation orchestration, barge-in | **iPhone** | All in `HY16Probe`, this repo |
| LLM (openai/gpt-5-nano) | **Internet** (OpenRouter) | One HTTPS request per user turn |
| TTS (Kokoro-82M, MLX) | **Mac**, same LAN as the iPhone | `direct-kokoro-service/server.py`, this repo |
| Speaker output | **HY-16 glasses**, via iPhone's normal Bluetooth-audio route | Not a BLE data transfer |
| Microphone input | **HY-16 glasses**, via BLE | Opus-encoded, 8kHz mono |

Nothing about this pipeline runs on the glasses themselves beyond audio
capture/playback and the BLE transport already built into their own
firmware — all intelligence (ASR, LLM, TTS, conversation state) lives on
the iPhone plus two network hops (OpenRouter, and the Mac's local Kokoro
service).

## Continuous conversation and barge-in

`JVConversationController` (see `docs/AI_CONVERSATION_PIPELINE.md` for
full detail) restarts ASR listening immediately after every final
transcript — *before* the LLM/TTS/playback for that turn even begins —
so the microphone is live for the entire duration the AI is
"thinking" or "speaking." This is what makes barge-in possible: if the
wearer starts talking while the AI is still replying, that speech is
already being captured, and two independent heuristics (an interim ASR
transcript that doesn't look like an echo of the AI's own speech, or
sustained voice-activity energy outside a short echo-protection window)
trigger an immediate, atomic interruption — cancelling the in-flight
LLM/TTS network requests and stopping playback.

A monotonically-incrementing `turnGeneration` counter, captured by every
async completion closure at the moment it's issued, prevents a stale
result from a just-cancelled turn from ever speaking after a newer turn
has already started (including the case where a cancelled
`URLSessionDataTask` still invokes its completion handler).

## Why a local Mac Kokoro service is a development architecture, not production

`direct-kokoro-service` exists to prove out low-latency TTS during
development: it requires the Mac to be running, on the same LAN as the
test iPhone, at a known/reachable IP address, for the entire duration of
testing. This is fine for one developer testing with one phone and one
Mac in one room. It is **not** how the real Joint Vibe product would
serve TTS to many users on many devices in many locations — a real
deployment needs either a properly hosted/scaled TTS backend (cloud or
edge) or an on-device/on-glasses solution, neither of which exists yet.
Anyone extending this project toward a real product needs to replace
this local-Mac dependency; nothing about the conversation
orchestration/barge-in architecture above depends on Kokoro specifically
being local — `VoiceStudioTTSService`/`GlassesSpeakerTestController`
already fall back cleanly to Apple's on-device TTS if the configured TTS
service is unreachable or unconfigured, which is the seam a future
production TTS backend would plug into.

## LAN IP addresses are not permanent configuration

`Secrets.plist`'s `VoiceStudioBaseURL` bakes in the Mac's current LAN IP.
This address is assigned by DHCP and can and does change between
sessions or when reconnecting to a network. Treat it as environment-
specific, re-verify it every time you set this project up (see
`docs/RECOVERY.md` step 6), and never assume a previously-working IP is
still correct — a stale IP here has already caused a real ~30-second
request-timeout regression once during development, with the app
silently falling back to a much lower-quality on-device voice rather
than failing loudly.
