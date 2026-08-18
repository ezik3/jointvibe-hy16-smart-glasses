# Mac Developer Environment Setup

Exact requirements to build and run this project. See `docs/RECOVERY.md`
for the full step-by-step recovery procedure this feeds into.

## Xcode

Required. Must support iOS SDK 16.0+ (`IPHONEOS_DEPLOYMENT_TARGET` in
`project.yml` is `16.0`). Last confirmed working against iOS SDK 26.5.
Install Command Line Tools alongside it (`xcode-select --install`).

## xcodegen (only if regenerating the project)

The checked-in `HY16Probe.xcodeproj` should normally open directly. Only
install/run `xcodegen` if that fails, or you deliberately change
`project.yml` and need to regenerate:

```bash
brew install xcodegen
xcodegen generate
```

## Swift packages

Resolved automatically by Xcode/`xcodebuild` from `project.yml`'s
`packages:` block and the committed `Package.resolved`. Exact pinned
versions — do not upgrade without a new physical test:

- **VLCKit** — `4.0.0-a23` (VideoLAN's official SPM distribution,
  `https://code.videolan.org/videolan/VLCKit.git`). Used only by the
  RTSP live-preview test path. Alpha version, deliberately — it tracks
  VLC core's rewritten clock architecture, which fixes a fixed-3-second
  video timestamp rejection bug present in the stable 3.0.x line.
- **swift-opus** (product name `Opus`) — `https://github.com/alta/swift-opus`,
  pinned to commit `6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8` (not the
  stale `0.0.2` tag, which is 25 PRs behind). Builds real libopus C
  source via SPM — no precompiled binary, no device/simulator slice
  ambiguity. Used for decoding the HY-16's Opus-encoded mic audio.

VLCKit's package manifest also downloads a separate binary
`.xcframework` artifact directly from `download.videolan.org` — this has
intermittently timed out during development (see `docs/RECOVERY.md`
step 25 for the exact symptom and fix — it has always been a transient
network issue, not a real dependency problem).

## Python (for direct-kokoro-service)

- **Python 3.11** (confirmed working: 3.11.15). Apple Silicon (arm64)
  Mac required — `mlx`/`mlx-audio` have no Intel equivalent.
- Create a virtual environment and install from
  `direct-kokoro-service/requirements.txt`:
  - `numpy==2.4.3` — array handling for the raw PCM samples before WAV
    encoding.
  - `mlx-audio==0.4.2` — Apple's MLX-based TTS inference library; this
    is what actually runs the Kokoro-82M model. Pulls in `mlx` itself as
    its own transitive dependency (not pinned separately — let pip
    resolve a version compatible with `mlx-audio==0.4.2`).
- The Kokoro-82M model weights (`mlx-community/Kokoro-82M-bf16`) are
  **not** bundled in this repository — `mlx_audio.tts.utils.load_model`
  downloads them from Hugging Face automatically on first run and caches
  them locally. Requires internet access the first time only.

## Networking

- `direct-kokoro-service` listens on **port 3902** on the Mac, and must
  be reachable from the iPhone over the same LAN/Wi-Fi network.
- The Mac's LAN IP is DHCP-assigned and can change between sessions —
  always re-verify it (`ipconfig getifaddr en0`) rather than reusing a
  previously-working value. See `docs/ARCHITECTURE.md`'s LAN IP warning
  for why this specifically matters here.

## iPhone code signing

- `DEVELOPMENT_TEAM` in `project.yml`/the generated `.xcodeproj` is
  currently set to a specific Apple Developer Team ID from the original
  development machine. **This is not portable** — set it to your own
  team's ID in Xcode's Signing & Capabilities pane (or in `project.yml`
  before regenerating) before you can build and run on your own device.
  Do not treat the committed value as something to copy into a new
  environment's documentation or scripts as if it were reusable.
- `CODE_SIGN_STYLE` is `Automatic` — Xcode will otherwise manage
  provisioning for you once the correct team is selected.
- The app requires a **physical iPhone**, not a Simulator — CoreBluetooth
  and the real microphone/BLE pipeline from the glasses do not work in
  Simulator.

## Troubleshooting package resolution

If Xcode reports missing package products (`VLCKit`/`Opus`) despite this
document's versions being correctly declared in `project.yml`: this has
consistently been a transient network timeout fetching VLCKit's binary
artifact, not a real configuration issue. See `docs/RECOVERY.md` step 25
for the exact recovery steps. Do not respond to this error by changing
package versions, removing a dependency, or regenerating the project —
none of those have ever been the actual cause when this has happened
during development.
