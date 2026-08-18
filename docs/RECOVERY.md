# Disaster Recovery — Fresh Mac, From Scratch

Assumes: the original Mac is completely gone, only this GitHub repository
remains, you have a new Mac, you have the physical HY-16 glasses, and you
have your own private OpenRouter credentials. Nothing below depends on
any file, environment variable, or cache that isn't either in this repo
or something you personally hold outside it (see "What you must still
have separately" at the end).

Start from tag `hy16-fast-conversation-pre-onboarding-recovery-v1`
(commit `8cb4dcf72ab7b65e93639df8ce3ca166c69a47e0`) unless you specifically
know a later commit on `main` is also physically verified.

## 1. Clone the repository

```bash
git clone https://github.com/ezik3/jointvibe-hy16-smart-glasses.git
cd jointvibe-hy16-smart-glasses
git checkout hy16-fast-conversation-pre-onboarding-recovery-v1
```

## 2. Install the correct Xcode

Xcode with iOS 16.0+ SDK support (this project's `IPHONEOS_DEPLOYMENT_TARGET`
is 16.0; it was last built successfully against iOS SDK 26.5 — a newer
Xcode than that should still work, an older one that predates iOS 16 SDK
support will not). Install command line tools too:

```bash
xcode-select --install
```

If you use `xcodegen` to regenerate `HY16Probe.xcodeproj` from
`project.yml` (only do this if the checked-in `.xcodeproj` won't open, or
you've deliberately changed `project.yml`):

```bash
brew install xcodegen
xcodegen generate
```

## 3. Resolve Swift packages — exact versions

Pinned in `HY16Probe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
already committed in this repo:

- **VLCKit** — `https://code.videolan.org/videolan/VLCKit.git`, version
  `4.0.0-a23`, revision `e3774eb25c62c902e9066ba267e6416d82e83382`.
- **swift-opus** (product name `Opus`) — `https://github.com/alta/swift-opus`,
  revision `6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8`.

Do not let Xcode "update to latest package versions" — that would move
off the known-good, physically-proven pins. Open the project and let it
resolve from the committed `Package.resolved`, or from Terminal:

```bash
xcodebuild -resolvePackageDependencies -project HY16Probe.xcodeproj -scheme HY16Probe
```

**Known issue:** VLCKit's package manifest downloads an additional binary
`.xcframework` artifact directly from `download.videolan.org` (separate
from the git checkout above). This download has been observed to
intermittently time out (`downloadError("The request timed out.")`),
producing a misleading `Missing package product 'VLCKit'` /
`Missing package product 'Opus'` error pair in Xcode (Opus fails too,
as a downstream consequence of VLCKit's package graph failing to
resolve — Opus itself is not the actual problem). If this happens:
confirm general internet connectivity, then simply retry — this has
consistently been a transient server-side timeout, not a real
configuration problem, every time it has been observed.

## 4. Recreate Secrets.plist from the template

```bash
cp HY16Probe/Secrets.plist.example HY16Probe/Secrets.plist
```

Then edit `HY16Probe/Secrets.plist` (never commit this file — it's
git-ignored) and fill in:

- `OpenRouterAPIKey` — your real key from https://openrouter.ai/keys
- `OpenRouterModelID` — leave as `openai/gpt-5-nano` to match the proven
  baseline, or change to test another model
- `VoiceStudioBaseURL` — see step 9 below, this is actually the direct
  Kokoro service URL despite the historical key name
- `VoiceStudioModelID` — `kokoro-direct`
- `VoiceStudioVoiceID` — `af_heart`
- `VoiceStudioPin` — leave empty (only used by the unrelated VoiceStudio
  wrapper this project no longer routes through)

## 5. (Same as step 4 — OpenRouter key configuration is covered above.)

## 6. Determine the Mac's current LAN IP

```bash
ipconfig getifaddr en0
```

**Do not reuse an old LAN IP from a previous machine or a previous
session on this same Mac.** This has already caused a real outage once
during development — a Mac's DHCP-assigned LAN IP changed between
sessions, `Secrets.plist` still pointed at the old address, and the
iPhone's requests to the Kokoro service silently timed out (~30+ seconds
per turn, falling back to the much lower-quality on-device Apple TTS
voice) with no error that made the cause obvious from the app alone.
Always verify the current IP fresh, every time you set this up.

## 7. Configure the Kokoro BaseURL using the CURRENT LAN IP

Set `VoiceStudioBaseURL` in `Secrets.plist` to
`http://<the IP from step 6>:3902` — e.g. `http://192.168.1.218:3902`.
The iPhone and the Mac must be on the same LAN/Wi-Fi network.

## 8. (Same as step 7.)

## 9. Create a Python virtual environment for direct-kokoro-service

Requires Apple Silicon (arm64) macOS — `mlx`/`mlx-audio` have no Intel
equivalent.

```bash
cd direct-kokoro-service
python3 -m venv .venv
source .venv/bin/activate
```

## 10. Install Kokoro dependencies

```bash
pip install -r requirements.txt
```

This installs the exact versions confirmed working during development:
`numpy==2.4.3`, `mlx-audio==0.4.2` (which pulls in `mlx` itself as a
transitive dependency). See `docs/SETUP_MAC.md` for what each package is
for.

## 11. Start direct-kokoro-service

```bash
python server.py
```

The Kokoro-82M model (`mlx-community/Kokoro-82M-bf16`) is downloaded
automatically from Hugging Face on first run and cached locally — this
requires internet access the first time only, and takes a little while.
The server loads the model once at startup and stays warm.

## 12. Verify port 3902

```bash
lsof -nP -iTCP:3902 -sTCP:LISTEN
```

Should show the `python` process from step 11 listening.

## 13. Benchmark/test Kokoro

```bash
curl -s -o test.wav -w "%{http_code} %{time_total}s\n" \
  -X POST http://127.0.0.1:3902/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro-direct","voice":"af_heart","input":"This is a latency test.","response_format":"wav"}'
file test.wav
```

Expect `HTTP 200`, a warm response time in the **0.2-0.4 second** range
(this is what was measured during development — a cold first request
will be slower while the model loads), and `test.wav` reported as a
valid RIFF/WAVE file. Then repeat the same request against the LAN IP
from step 6/7 instead of `127.0.0.1`, since that's what the iPhone will
actually use.

## 14. (Same as step 13 — benchmark covers both localhost and LAN.)

## 15. Open/build HY16Probe

```bash
open HY16Probe.xcodeproj
```

Select your physical iPhone as the run destination (not a simulator —
this app requires real CoreBluetooth hardware and a real microphone
pipeline from the glasses; nothing about BLE/audio works in Simulator).
`DEVELOPMENT_TEAM` in `project.yml`/`project.pbxproj` is currently
pinned to a specific Apple Developer Team ID from the original
development machine — you will need to change this to your own team's
ID in Xcode's Signing & Capabilities pane (or in `project.yml` if you
regenerate via xcodegen) before you can build/sign for your own device.

## 16. Connect physical iPhone

Trust the developer certificate on the iPhone if prompted
(Settings → General → VPN & Device Management), then Run from Xcode.

## 17. Connect HY-16

In the app: "Scan for Glasses" → tap the discovered HY-16 device to
connect.

## 18. Start AI Dialogue

Physically trigger AI Dialogue mode on the glasses themselves (button
press or voice wake, per the manufacturer's own device UI) — the app
observes this via the `0x0805` notification, it does not trigger it.

## 19. Start BLE audio

In the "Audio Capture/Decode Test" section, tap **START AUDIO CAPTURE**
— this sends `0x0A02` value 1 (enable 8kHz mic uplink) and begins
decoding the resulting `0x0A03` Opus packets.

## 20. Start speech test

In the "JV AI — SPEECH TEST" section, tap **START SPEECH TEST**. This
begins the continuous conversation loop.

## 21. Verify microphone → ASR → GPT-5-nano → Kokoro → glasses speaker

Speak to the glasses. Watch the Log section for, in order: BLE audio
packets arriving, `JVSpeechTest: final transcript received`, `AIService:
LLM request sent` → `LLM response received`, `VoiceStudioTTS: TTS
request sent` → `TTS audio received`, `GlassesSpeakerTest: playback
requested`. You should hear the reply from the **HY-16's own speaker**,
not the iPhone.

## 22. Verify continuous conversation

After the AI finishes speaking, it should automatically start listening
again with no additional button press — have a second and third
back-and-forth turn.

## 23. Verify barge-in

Start talking while the AI is still speaking its reply — it should stop
immediately (watch for `JV BARGE-IN: interruption accepted` in the log).

## 24. Verify the 900ms endpoint

Speak a short phrase and go silent — the app should finalize your
utterance roughly 900ms after you stop talking, not immediately and not
after a long pause. (Constant defined in
`JVSpeechTestController.silenceEndpointDurationMs`.)

## 25. Troubleshooting: VLCKit package download timeout

If Xcode reports `Missing package product 'VLCKit'` (and usually `'Opus'`
alongside it as a downstream consequence): this has always been a
transient timeout fetching VLCKit's binary artifact from
`download.videolan.org`, not a real problem with this project's package
configuration. Steps, in order:

1. Confirm general internet connectivity (`curl -I https://download.videolan.org`).
2. Retry: `xcodebuild -resolvePackageDependencies -project HY16Probe.xcodeproj -scheme HY16Probe`, or just try Run again in Xcode.
3. If Xcode was already open while you changed/regenerated the project file, close and reopen the project — Xcode's in-memory package graph does not always notice an externally-regenerated `.xcodeproj`.

Do not "fix" this by changing package versions, removing VLCKit, or
regenerating dependencies — none of that was ever the actual cause.

## 26. Manufacturer SDK/protocol material

The manufacturer's own BES/HY-16 SDK archives and protocol documents are
**not** in this repository — see `vendor-reference/README.md` for where
they are kept and why. You will need your own copy of that material
(from wherever you originally obtained it) if you need to consult the
manufacturer's documentation directly; everything this project has
*independently, physically proven* about the protocol is instead
documented in `docs/HY16_PROTOCOL_NOTES.md`, which needs nothing beyond
this repository.

## What you must still have separately (this repo cannot restore these)

- The physical HY-16 glasses themselves.
- Your own OpenRouter account/API key.
- Your own Apple Developer account/Team ID for code signing.
- The manufacturer's BES/HY-16 SDK archive and protocol documents, if you
  need to consult manufacturer documentation beyond what's proven in
  `docs/HY16_PROTOCOL_NOTES.md` (see `vendor-reference/README.md`).
