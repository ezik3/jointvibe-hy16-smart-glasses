//
//  OpenRouterAIService.swift
//  HY16Probe
//
//  JV AI - LLM-in-the-loop (approved pass). First real AI backend for the
//  closed conversational loop: HY-16 speech -> existing proven Apple
//  Speech transcript -> this service -> AI-generated reply -> existing
//  proven GlassesSpeakerTestController.speak(_:) -> HY-16 speaker.
//
//  Completely isolated: no CoreBluetooth/Opus/Speech import, no knowledge
//  of BLEScanner/JVSpeechTestController/GlassesSpeakerTestController. Only
//  conforms to AIResponding (String in, String out). Does not touch the
//  proven mic/BLE/Opus/VAD path or the proven speaker path in any way -
//  ContentView.swift is the only place this service is wired to either.
//
//  CONFIGURATION / SECURITY: model ID and API key are read from
//  HY16Probe/Secrets.plist, a local, git-ignored file (see .gitignore and
//  Secrets.plist.example, the tracked, no-secret template). Neither the
//  API key NOR the full Secrets.plist contents are ever logged - only
//  whether configuration was found, and which model ID (not a secret) is
//  in use. If Secrets.plist is missing/incomplete, respond(to:completion:)
//  fails cleanly via .failure(ServiceError.missingConfiguration) - it
//  never crashes and never silently no-ops, and a failure here cannot
//  affect the proven BLE/mic/VAD pipeline, which has already returned to
//  .idle before this service is ever called (see JVSpeechTestController's
//  onFinalTranscript firing point).
//
//  MODEL SELECTION (checked against OpenRouter's live public model
//  catalog - https://openrouter.ai/api/v1/models, no auth required - on
//  2026-08-16, not assumed from stale training data): default model ID
//  in Secrets.plist.example is "openai/gpt-5-nano" ($0.025/M input,
//  $0.20/M output tokens at the time checked) - recommended over the
//  free "nvidia/nemotron-3.5-lightning:free" tier for this FIRST physical
//  latency test specifically because free-tier routing on OpenRouter is
//  more prone to inconsistent queuing/latency, which would confound the
//  very round-trip-latency measurement this milestone exists to produce;
//  at gpt-5-nano's price a single exchange costs a small fraction of a
//  cent, so the free tier's cost savings don't outweigh that risk here.
//  The model ID is entirely config-driven (Secrets.plist), never
//  hardcoded below, so switching models - including to the free tier -
//  needs zero code change.
//

import Foundation

final class OpenRouterAIService: ObservableObject, AIResponding {

    // MARK: Latency instrumentation hook (approved pass). Optional
    // closure, set by ContentView to JVLatencyTracker.record(_:). Fired
    // at the same moments the existing "LLM request sent"/"LLM response
    // received" log lines already fire, below. Nil (never set) is a
    // no-op - changes nothing about the LLM request itself.
    var onLatencyCheckpoint: ((String) -> Void)?

    enum ServiceError: Error, LocalizedError {
        case missingConfiguration
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "OpenRouter API key/model not configured - see HY16Probe/Secrets.plist.example"
            case .invalidResponse:
                return "OpenRouter response could not be parsed"
            case .httpError(let code):
                return "OpenRouter HTTP error \(code)"
            }
        }
    }

    /// Isolated, replaceable-later system instruction for a voice
    /// assistant persona. Kept as a single named constant so a future
    /// pass can swap in the real JV personality/profile system without
    /// touching request-building logic.
    private static let systemPrompt =
        "You are the Joint Vibe smart-glasses voice assistant. Respond naturally and conversationally. Keep spoken answers concise unless the user asks for more detail."

    private static let endpointURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private struct Config {
        let apiKey: String
        let modelID: String

        /// Reads HY16Probe/Secrets.plist (git-ignored, see .gitignore).
        /// Returns nil - never throws/crashes - if the file is missing or
        /// either field is absent/empty, so a fresh checkout without
        /// Secrets.plist fails safely rather than force-unwrapping.
        static func loadFromSecretsPlist() -> Config? {
            guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let apiKey = plist["OpenRouterAPIKey"] as? String,
                  !apiKey.isEmpty, apiKey != "REPLACE_WITH_YOUR_OPENROUTER_API_KEY",
                  let modelID = plist["OpenRouterModelID"] as? String,
                  !modelID.isEmpty
            else {
                return nil
            }
            return Config(apiKey: apiKey, modelID: modelID)
        }
    }

    private let log: (String) -> Void
    private let config: Config?
    // Session-lifetime only (no disk persistence this pass, per explicit
    // scope) - [role: String, content: String] pairs, matching
    // OpenRouter's own "messages" array shape exactly.
    private var conversation: [[String: String]]

    init(log: @escaping (String) -> Void) {
        self.log = log
        let loadedConfig = Config.loadFromSecretsPlist()
        self.config = loadedConfig
        self.conversation = [["role": "system", "content": Self.systemPrompt]]
        if let loadedConfig {
            log("AIService: configuration loaded (model=\(loadedConfig.modelID)) - API key present, value never logged")
        } else {
            log("AIService: Secrets.plist missing or incomplete - LLM requests will fail until configured (see Secrets.plist.example)")
        }
    }

    @discardableResult
    func respond(to transcript: String, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        log("AIService: final transcript ready - \"\(transcript)\"")

        guard let config else {
            log("AIService: LLM request ABORTED - no configuration")
            completion(.failure(ServiceError.missingConfiguration))
            return nil
        }

        conversation.append(["role": "user", "content": transcript])

        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        // Latency experiment (approved pass, live-verified against this
        // exact model/config via direct SSE testing before implementation):
        // reasoning.effort=minimal cut LLM latency from a highly variable
        // 3.8-11.4s down to a consistent 1.4-1.75s in repeated live tests,
        // because GPT-5-family models otherwise emit an unbounded amount
        // of invisible "reasoning" content before any visible answer text.
        // Not exposed as a Secrets.plist toggle - this is a direct,
        // single-field request change, isolated to this one dictionary.
        let body: [String: Any] = [
            "model": config.modelID,
            "messages": conversation,
            "reasoning": ["effort": "minimal"]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            log("AIService: LLM request ABORTED - could not encode request body")
            completion(.failure(ServiceError.invalidResponse))
            return nil
        }
        request.httpBody = bodyData

        let requestSentDate = Date()
        log("AIService: LLM request sent (model=\(config.modelID))")
        onLatencyCheckpoint?("llmRequestSent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let elapsedSeconds = Date().timeIntervalSince(requestSentDate)
            DispatchQueue.main.async {
                if let error {
                    self.log("AIService: LLM request FAILED after \(String(format: "%.2f", elapsedSeconds))s: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200 else {
                    self.log("AIService: LLM request FAILED after \(String(format: "%.2f", elapsedSeconds))s - HTTP \(statusCode)")
                    completion(.failure(ServiceError.httpError(statusCode)))
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty
                else {
                    self.log("AIService: LLM response received after \(String(format: "%.2f", elapsedSeconds))s but could not be parsed")
                    completion(.failure(ServiceError.invalidResponse))
                    return
                }
                self.log("AIService: LLM response received")
                self.log("AIService: LLM latency = \(String(format: "%.2f", elapsedSeconds))s")
                self.onLatencyCheckpoint?("llmResponseComplete")
                self.conversation.append(["role": "assistant", "content": content])
                completion(.success(content))
            }
        }
        task.resume()
        return task
    }
}
