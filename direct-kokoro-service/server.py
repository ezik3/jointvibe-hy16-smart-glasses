#!/usr/bin/env python3
"""
direct-kokoro-service - EXPERIMENTAL, DEV-ONLY (approved pass).

NOT a production component. NOT something a Joint Vibe customer ever
installs, sees, or configures. This exists to answer exactly one
question: how fast can our proven HY-16 conversational pipeline become
once VoiceStudio's own wrapper overhead (admission-control/pooling/text-
normalization/DB-lookup layers, confirmed from its source in an earlier
forensic pass) is removed and the Kokoro model is loaded ONCE and kept
warm, rather than reloaded per request (as a bare CLI invocation would).

This script also approximates - in shape only, not in production
robustness - what a single future JV-hosted cloud Kokoro worker would
look like: one persistent process, one resident model, one minimal HTTP
endpoint. It is not that worker. It has no auth, no concurrency control,
no queueing, no autoscaling, and is not meant to run beyond this
experiment.

Uses ONLY Python's standard library (http.server, wave, json) plus
mlx_audio and numpy, which are already installed in VoiceStudio's own
venv - nothing new is installed, nothing about that venv or the VoiceStudio
app is modified. VoiceStudio itself (ports 3900/3901) is untouched and
keeps running exactly as before; this binds to port 3902, a distinct port,
so the two can run simultaneously with zero interference.

REQUEST/RESPONSE SHAPE (deliberately identical to VoiceStudioTTSService.swift's
existing request, so that Swift file needs ZERO code changes to point at
this service instead of VoiceStudio - only Secrets.plist's VoiceStudioBaseURL
needs to change, and reverting is the same edit in reverse):

  POST /v1/audio/speech
  Content-Type: application/json
  {"model": "...", "voice": "af_heart", "input": "text to speak", "response_format": "wav"}

  -> 200 OK, Content-Type: audio/wav, complete WAV bytes (16-bit PCM,
     mono, Kokoro's own sample rate - confirmed 24000 Hz, matching what
     VoiceStudio's own /v1/audio/speech already returns and what
     GlassesSpeakerTestController.playSynthesizedAudio(_:) already
     consumes with zero conversion).

"model" and "response_format" are accepted but not meaningfully used
(this service only ever runs Kokoro, only ever returns WAV) - present
purely so the exact same request body VoiceStudioTTSService already
builds is a valid, ignorable-superset request here too.
"""

import json
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

MODEL_REPO = "mlx-community/Kokoro-82M-bf16"
DEFAULT_VOICE = "af_heart"
DEFAULT_LANG_CODE = "a"
PORT = 3902

print(f"direct-kokoro-service: loading {MODEL_REPO} (one-time, kept resident)...", flush=True)
_load_start = time.time()
from mlx_audio.tts.utils import load_model  # noqa: E402  (import after print, deliberately)
MODEL = load_model(MODEL_REPO)
_load_elapsed = time.time() - _load_start
print(f"direct-kokoro-service: model loaded and resident in {_load_elapsed:.3f}s", flush=True)


def synthesize_wav_bytes(text: str, voice: str, speed: float = 1.0) -> bytes:
    t0 = time.time()
    results = list(MODEL.generate(text=text, voice=voice, speed=speed, lang_code=DEFAULT_LANG_CODE))
    elapsed = time.time() - t0

    if not results:
        raise ValueError("Kokoro produced no audio for this input")

    sample_rate = results[0].sample_rate
    audio = np.concatenate([np.asarray(r.audio) for r in results])
    audio_duration = len(audio) / sample_rate if sample_rate else 0.0

    # Kokoro's own audio arrays are float samples in [-1.0, 1.0] - convert
    # to 16-bit PCM, matching exactly what VoiceStudio's /v1/audio/speech
    # already returns and what our proven playback path already expects.
    int16_audio = np.clip(audio * 32767.0, -32768, 32767).astype(np.int16)

    import io
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(int16_audio.tobytes())
    wav_bytes = buffer.getvalue()

    rtf = elapsed / audio_duration if audio_duration else 0.0
    print(
        f"direct-kokoro-service: synthesized {audio_duration:.3f}s of audio in "
        f"{elapsed:.3f}s (RTF={rtf:.3f}) for voice={voice!r} text={text[:60]!r}...",
        flush=True,
    )
    return wav_bytes


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep stdout focused on the timing lines above; suppress the
        # default per-request access log noise.
        pass

    def do_POST(self):
        if self.path != "/v1/audio/speech":
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            request = json.loads(body)
            text = request.get("input", "")
            voice = request.get("voice") or DEFAULT_VOICE
            if voice in ("default", "alloy", "echo", "fable", "onyx", "nova", "shimmer"):
                voice = DEFAULT_VOICE
            speed = float(request.get("speed", 1.0))

            if not text:
                self.send_response(400)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Missing required 'input' text field")
                return

            wav_bytes = synthesize_wav_bytes(text=text, voice=voice, speed=speed)

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav_bytes)))
            self.send_header("Content-Disposition", 'inline; filename="speech.wav"')
            self.end_headers()
            self.wfile.write(wav_bytes)
        except Exception as e:
            print(f"direct-kokoro-service: request FAILED: {e}", flush=True)
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(str(e).encode("utf-8"))


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"direct-kokoro-service: listening on 0.0.0.0:{PORT} (dev-only, no auth, not for production)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("direct-kokoro-service: shutting down", flush=True)
        sys.exit(0)
