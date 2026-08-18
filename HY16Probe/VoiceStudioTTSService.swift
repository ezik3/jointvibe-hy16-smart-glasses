//
//  VoiceStudioTTSService.swift
//  HY16Probe
//
//  JV AI - VoiceStudio TTS (approved pass). Replaces ONLY the voice
//  generation step of the closed conversational loop:
//    HY-16 speech -> existing proven ASR/VAD -> existing proven OpenRouter
//    LLM -> THIS -> existing proven GlassesSpeakerTestController playback.
//  GlassesSpeakerTestController.speak(_:) (AVSpeechSynthesizer/Apple TTS)
//  is completely untouched and remains the fallback path if this service
//  fails or is unconfigured - see ContentView.swift's onFinalTranscript
//  wiring.
//
//  Completely isolated: no CoreBluetooth/Opus/Speech import, no knowledge
//  of BLEScanner/JVSpeechTestController/GlassesSpeakerTestController.
//  Only conforms to TTSGenerating (String in, Data out).
//
//  API SHAPE (verified live against voicestudio.sh's own docs and GitHub
//  repo - debpalash/VoiceStudio, AGPL-3.0 - on 2026-08-16, not assumed):
//  OpenAI-compatible POST <baseURL>/v1/audio/speech, JSON body
//  {"model": ..., "voice": ..., "input": ..., "response_format": "wav"}.
//  "wav" is requested specifically because it is self-describing (sample
//  rate/bit depth/channels embedded in the file header) - AVAudioPlayer
//  can consume the returned Data directly with NO manual format
//  conversion or sample-rate assumption, unlike the mic-uplink Opus path.
//
//  CONFIGURATION: baseURL/model/voice/optional LAN share-PIN are all read
//  from HY16Probe/Secrets.plist (local, git-ignored - see .gitignore and
//  Secrets.plist.example). NONE of these are hardcoded here, so the
//  engine/model/voice can be A/B tested by editing Secrets.plist only -
//  zero Swift changes. The engine/voice ID defaults in
//  Secrets.plist.example are explicitly UNVERIFIED PLACEHOLDERS (see that
//  file's own comments) - this service treats them exactly like
//  OpenRouterAIService treats its own placeholder API key: if the
//  configured model/voice ID still equals the placeholder sentinel,
//  configuration is treated as incomplete and synthesize(_:) fails
//  cleanly via .failure(ServiceError.missingConfiguration) rather than
//  ever sending a fabricated/guessed ID to a real API call.
//
//  PIN (share-PIN LAN auth, per VoiceStudio's documented api-auth.md):
//  sent as the "X-OmniVoice-Pin" header when VoiceStudioPin is non-empty
//  in Secrets.plist. Empty/absent is valid (e.g. testing on the same Mac
//  via loopback, or a network already covered by VoiceStudio's own
//  OMNIVOICE_TRUSTED_NETWORKS server-side exemption) - never required by
//  this code, only sent if configured.
//

import Foundation

final class VoiceStudioTTSService: ObservableObject, TTSGenerating {

    // MARK: Latency instrumentation hook (approved pass). Optional
    // closure, set by ContentView to JVLatencyTracker.record(_:). Fired
    // at the same moments the existing "TTS request sent"/"TTS audio
    // received" log lines already fire, below. Nil (never set) is a
    // no-op - changes nothing about the TTS request itself.
    var onLatencyCheckpoint: ((String) -> Void)?

    enum ServiceError: Error, LocalizedError {
        case missingConfiguration
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "VoiceStudio base URL/model/voice not configured - see HY16Probe/Secrets.plist.example"
            case .invalidResponse:
                return "VoiceStudio response could not be read as audio data"
            case .httpError(let code):
                return "VoiceStudio HTTP error \(code)"
            }
        }
    }

    private struct Config {
        let baseURL: URL
        let modelID: String
        let voiceID: String
        let pin: String?

        private static let unverifiedModelPlaceholder = "REPLACE_WITH_VERIFIED_ENGINE_ID"
        private static let unverifiedVoicePlaceholder = "REPLACE_WITH_VERIFIED_VOICE_ID"
        private static let unconfiguredBaseURLPlaceholder = "REPLACE_WITH_YOUR_MAC_LAN_IP"

        /// Reads HY16Probe/Secrets.plist (git-ignored, see .gitignore).
        /// Returns nil - never throws/crashes - if the file is missing,
        /// any required field is absent/empty, or a field still equals
        /// its documented unverified/unconfigured placeholder sentinel.
        static func loadFromSecretsPlist() -> Config? {
            guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else {
                return nil
            }
            guard let baseURLString = plist["VoiceStudioBaseURL"] as? String,
                  !baseURLString.isEmpty,
                  !baseURLString.contains(unconfiguredBaseURLPlaceholder),
                  let baseURL = URL(string: baseURLString)
            else {
                return nil
            }
            guard let modelID = plist["VoiceStudioModelID"] as? String,
                  !modelID.isEmpty, modelID != unverifiedModelPlaceholder
            else {
                return nil
            }
            guard let voiceID = plist["VoiceStudioVoiceID"] as? String,
                  !voiceID.isEmpty, voiceID != unverifiedVoicePlaceholder
            else {
                return nil
            }
            let pin = (plist["VoiceStudioPin"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Config(baseURL: baseURL, modelID: modelID, voiceID: voiceID, pin: pin)
        }
    }

    private let log: (String) -> Void
    private let config: Config?

    init(log: @escaping (String) -> Void) {
        self.log = log
        let loadedConfig = Config.loadFromSecretsPlist()
        self.config = loadedConfig
        if let loadedConfig {
            log("VoiceStudioTTS: configuration loaded (baseURL=\(loadedConfig.baseURL.absoluteString), model=\(loadedConfig.modelID), voice=\(loadedConfig.voiceID), pin=\(loadedConfig.pin != nil ? "configured, not logged" : "not configured"))")
        } else {
            log("VoiceStudioTTS: Secrets.plist missing/incomplete VoiceStudio* keys - TTS requests will fail until configured (see Secrets.plist.example); GlassesSpeakerTestController.speak(_:) (Apple TTS) will be used as a fallback")
        }
    }

    @discardableResult
    func synthesize(text: String, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask? {
        guard let config else {
            log("VoiceStudioTTS: synthesize(_:) ABORTED - no configuration")
            completion(.failure(ServiceError.missingConfiguration))
            return nil
        }

        let endpoint = config.baseURL.appendingPathComponent("v1/audio/speech")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let pin = config.pin {
            request.setValue(pin, forHTTPHeaderField: "X-OmniVoice-Pin")
        }
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": config.modelID,
            "voice": config.voiceID,
            "input": text,
            "response_format": "wav"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            log("VoiceStudioTTS: synthesize(_:) ABORTED - could not encode request body")
            completion(.failure(ServiceError.invalidResponse))
            return nil
        }
        request.httpBody = bodyData

        let requestSentDate = Date()
        log("VoiceStudioTTS: TTS request sent (model=\(config.modelID), voice=\(config.voiceID))")
        onLatencyCheckpoint?("ttsRequestSent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let elapsedSeconds = Date().timeIntervalSince(requestSentDate)
            DispatchQueue.main.async {
                if let error {
                    self.log("VoiceStudioTTS: TTS request FAILED after \(String(format: "%.2f", elapsedSeconds))s: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200 else {
                    self.log("VoiceStudioTTS: TTS request FAILED after \(String(format: "%.2f", elapsedSeconds))s - HTTP \(statusCode)")
                    completion(.failure(ServiceError.httpError(statusCode)))
                    return
                }
                guard let data, !data.isEmpty else {
                    self.log("VoiceStudioTTS: TTS response received after \(String(format: "%.2f", elapsedSeconds))s but contained no audio data")
                    completion(.failure(ServiceError.invalidResponse))
                    return
                }
                self.log("VoiceStudioTTS: TTS audio received (\(data.count) bytes, WAV - no conversion needed)")
                self.log("VoiceStudioTTS: TTS latency = \(String(format: "%.2f", elapsedSeconds))s")
                self.onLatencyCheckpoint?("ttsComplete")
                completion(.success(data))
            }
        }
        task.resume()
        return task
    }
}
