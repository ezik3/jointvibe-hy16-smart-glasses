//
//  JointVibeGatewayProvider.swift
//  HY16Probe
//
//  M0 STEP 1 (approved pass) - authenticated Joint Vibe ai-gateway AI
//  backend, an ALTERNATIVE to OpenRouterAIService, not a replacement.
//  Conforms to the SAME AIResponding protocol OpenRouterAIService already
//  conforms to (String transcript in, String reply out) specifically so
//  JVConversationController's existing beginSpeaking(reply:generation:)
//  -> voiceStudioTTS -> glassesSpeakerTest chain can be reused completely
//  UNCHANGED - this file's only job is to become a second, swappable
//  source of the reply text. Does NOT touch BLE/Opus/Speech/Kokoro/
//  GlassesSpeakerTestController in any way - no import of any of those.
//
//  STEP 1 IS BUFFERED, PER EXPLICIT SCOPE: this file receives the full
//  SSE stream via a single URLSession completion-handler request (the
//  SAME dataTask(with:completionHandler:) pattern OpenRouterAIService/
//  VoiceStudioTTSService already use elsewhere in this project - no new
//  streaming-delegate architecture introduced this pass), and only calls
//  its own completion once the ENTIRE response has been received and
//  parsed. Sentence-boundary/first-sentence TTS is explicitly STEP 2,
//  not implemented here.
//
//  AUTH (dev-only, per explicit M0 instruction): runtime email/password
//  entry (ContentView.swift), access_token/refresh_token/expiresAt held
//  IN MEMORY ONLY on this class - never written to disk, never in
//  Secrets.plist, never logged. Relaunching the app requires signing in
//  again - explicitly acceptable for this pass. Refresh is single-flight
//  (isRefreshing + a waiter queue) because Supabase refresh-token
//  rotation is enabled server-side and two concurrent refreshes risk a
//  reuse-window collision on the same about-to-rotate refresh token.
//
//  SILENT ANONYMOUS FALLBACK (the auth-reality investigated and verified
//  against the live deployed gateway): the gateway has verify_jwt=false
//  and never returns 401 for a missing/expired/malformed/invalid-user
//  JWT - it silently answers as an anonymous user instead, signalled
//  ONLY by the X-Remaining-Tokens response header equalling "-1". This
//  file treats that condition as an authentication failure, not a
//  successful turn: refreshes exactly once, retries the SAME turn
//  (same client_turn_id) exactly once, and if -1 persists, fails the
//  turn with GatewayError.silentAuthenticationFailure rather than
//  returning the anonymous answer as if it were a real one.
//
//  Configuration (Supabase project URL + publishable/anon key - NOT
//  secrets, per explicit instruction) is read from Secrets.plist, the
//  same git-ignored local file OpenRouterAIService/VoiceStudioTTSService
//  already read from - see Secrets.plist.example for the placeholder
//  keys this pass adds. The Supabase SERVICE ROLE key must never exist
//  anywhere in this file, this project, or this repository.
//

import Foundation

final class JointVibeGatewayProvider: ObservableObject, AIResponding {

    enum AuthState: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case requiresSignIn(reason: String)

        var description: String {
            switch self {
            case .signedOut: return "Signed out"
            case .signingIn: return "Signing in…"
            case .signedIn: return "Signed in"
            case .requiresSignIn(let reason): return "Sign-in required (\(reason))"
            }
        }
    }

    enum GatewayError: Error, LocalizedError, Equatable {
        case missingConfiguration
        case notSignedIn
        case invalidResponse
        case httpError(Int)
        case quotaOrRateLimited
        case paymentRequired
        case silentAuthenticationFailure

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Supabase URL/anon key not configured - see HY16Probe/Secrets.plist.example"
            case .notSignedIn:
                return "Not signed in to Joint Vibe"
            case .invalidResponse:
                return "Joint Vibe gateway response could not be parsed"
            case .httpError(let code):
                return "Joint Vibe gateway HTTP error \(code)"
            case .quotaOrRateLimited:
                return "Joint Vibe usage limit reached"
            case .paymentRequired:
                return "Joint Vibe payment required"
            case .silentAuthenticationFailure:
                return "Joint Vibe authentication failed (silent anonymous fallback detected)"
            }
        }
    }

    // MARK: Published diagnostic state - mirrors the pattern every other
    // controller in this project uses for UI-visible state.
    @Published private(set) var authState: AuthState = .signedOut
    @Published private(set) var lastSessionID: String?
    @Published private(set) var lastIntent: String?
    @Published private(set) var lastRemainingTokens: String?

    // MARK: Latency instrumentation hook (same convention as
    // OpenRouterAIService/VoiceStudioTTSService). Optional, nil-safe.
    var onLatencyCheckpoint: ((String) -> Void)?

    private struct Config {
        let supabaseURL: URL
        let anonKey: String

        static let unconfiguredURLPlaceholder = "REPLACE_WITH_YOUR_SUPABASE_URL"
        static let unconfiguredKeyPlaceholder = "REPLACE_WITH_YOUR_SUPABASE_ANON_KEY"

        static func loadFromSecretsPlist() -> Config? {
            guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let urlString = plist["SupabaseURL"] as? String,
                  !urlString.isEmpty, urlString != unconfiguredURLPlaceholder,
                  let supabaseURL = URL(string: urlString),
                  let anonKey = plist["SupabaseAnonKey"] as? String,
                  !anonKey.isEmpty, anonKey != unconfiguredKeyPlaceholder
            else {
                return nil
            }
            return Config(supabaseURL: supabaseURL, anonKey: anonKey)
        }
    }

    private let log: (String) -> Void
    private let config: Config?

    // MARK: In-memory-only auth state (per explicit M0 instruction - NEVER
    // persisted to disk, NEVER in Secrets.plist, NEVER logged in full).
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?

    // MARK: Single-flight refresh guard - see file header.
    private var isRefreshing = false
    private var refreshWaiters: [(Bool) -> Void] = []

    // MARK: Session continuity - captured from the FIRST successful
    // turn's X-Session-Id response header, reused as the "session_id"
    // request field on every subsequent turn. Never generated locally.
    private var sessionID: String?

    // MARK: Local conversation history - mirrors OpenRouterAIService's
    // own `conversation` array shape/lifecycle exactly (session-lifetime
    // only, no disk persistence), so the two providers behave
    // consistently from JVConversationController's point of view. Only
    // ever appended to on a turn that both received SSE content AND was
    // not a silently-anonymous (-1) result - see respond(to:completion:).
    private var conversation: [[String: String]] = []

    init(log: @escaping (String) -> Void) {
        self.log = log
        let loadedConfig = Config.loadFromSecretsPlist()
        self.config = loadedConfig
        if loadedConfig != nil {
            log("JointVibeGateway: configuration loaded (Supabase URL present) - anon key present, value never logged")
        } else {
            log("JointVibeGateway: Secrets.plist missing/incomplete SupabaseURL/SupabaseAnonKey - M0 gateway calls will fail until configured (see Secrets.plist.example)")
        }
    }

    // MARK: - Sign-in (M0 dev-only, runtime credentials)

    /// Called only from an explicit user tap on "Sign In" in ContentView's
    /// M0 test section. `password` is used exactly once, for this one
    /// request body, and is never retained by this class afterward -
    /// there is no stored property for it anywhere in this file.
    func signIn(email: String, password: String, completion: @escaping (Bool) -> Void) {
        guard let config else {
            log("JointVibeGateway: sign-in ABORTED - no Supabase configuration")
            authState = .requiresSignIn(reason: "not configured")
            completion(false)
            return
        }
        guard var components = URLComponents(url: config.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            completion(false)
            return
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let url = components.url else {
            completion(false)
            return
        }

        authState = .signingIn
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        log("JointVibeGateway: sign-in requested (credentials never logged)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard error == nil, statusCode == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String,
                      let refreshToken = json["refresh_token"] as? String,
                      let expiresIn = json["expires_in"] as? Double
                else {
                    self.log("JointVibeGateway: sign-in FAILED (HTTP \(statusCode))")
                    self.authState = .requiresSignIn(reason: "sign-in failed")
                    completion(false)
                    return
                }
                self.accessToken = accessToken
                self.refreshToken = refreshToken
                self.expiresAt = Date().addingTimeInterval(expiresIn)
                self.authState = .signedIn
                self.log("JointVibeGateway: sign-in SUCCEEDED (expires in \(Int(expiresIn))s)")
                completion(true)
            }
        }.resume()
    }

    /// Clears in-memory auth state only. Does not touch conversation
    /// history or any other file's behavior.
    func signOut() {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        sessionID = nil
        authState = .signedOut
        log("JointVibeGateway: signed out - in-memory tokens cleared")
    }

    // MARK: - Session verification probe (recommended for the first M0
    // physical test - see docs/reconciliation history). Unlike the
    // ai-gateway itself, /auth/v1/user genuinely returns 401 for an
    // invalid/expired token, so this is a real, unambiguous pre-flight
    // signal before any HY-16 hardware interaction begins.

    func verifySession(completion: @escaping (Bool) -> Void) {
        guard let config, let accessToken else {
            completion(false)
            return
        }
        var request = URLRequest(url: config.supabaseURL.appendingPathComponent("auth/v1/user"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        log("JointVibeGateway: verifying session via /auth/v1/user")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let ok = statusCode == 200
                self.log("JointVibeGateway: /auth/v1/user -> HTTP \(statusCode) (\(ok ? "OK" : "FAILED"))")
                completion(ok)
            }
        }.resume()
    }

    // MARK: - Pre-warm (fire-and-forget, independent of any turn/session
    // state - see file header. Recommended to call once when M0 mode
    // starts, not per-turn.)

    func prewarm() {
        guard let config else { return }
        var request = URLRequest(url: config.supabaseURL.appendingPathComponent("functions/v1/ai-gateway"))
        request.httpMethod = "GET"
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        log("JointVibeGateway: pre-warm GET sent")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async {
                self?.log("JointVibeGateway: pre-warm response HTTP \(statusCode)")
            }
        }.resume()
    }

    // MARK: - Refresh (single-flight, see file header)

    private func refreshIfPossible(completion: @escaping (Bool) -> Void) {
        guard let config, let refreshToken else {
            completion(false)
            return
        }
        if isRefreshing {
            refreshWaiters.append(completion)
            return
        }
        isRefreshing = true
        log("JointVibeGateway: refreshing access token")

        guard var components = URLComponents(url: config.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            isRefreshing = false
            completion(false)
            return
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components.url else {
            isRefreshing = false
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                var success = false
                if error == nil, statusCode == 200, let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccessToken = json["access_token"] as? String,
                   let newRefreshToken = json["refresh_token"] as? String,
                   let expiresIn = json["expires_in"] as? Double {
                    self.accessToken = newAccessToken
                    self.refreshToken = newRefreshToken // rotation: ALWAYS replace with the new one
                    self.expiresAt = Date().addingTimeInterval(expiresIn)
                    self.log("JointVibeGateway: refresh SUCCEEDED")
                    success = true
                } else {
                    self.log("JointVibeGateway: refresh FAILED (HTTP \(statusCode)) - clearing tokens, sign-in required")
                    self.accessToken = nil
                    self.refreshToken = nil
                    self.expiresAt = nil
                    self.authState = .requiresSignIn(reason: "refresh failed")
                }
                self.isRefreshing = false
                let waiters = self.refreshWaiters
                self.refreshWaiters = []
                completion(success)
                waiters.forEach { $0(success) }
            }
        }.resume()
    }

    // MARK: - AIResponding conformance - the actual M0 gateway turn.
    // This is the ONLY method JVConversationController's new M0 branch
    // calls - everything above exists to support this one call being
    // safe to make.

    @discardableResult
    func respond(to transcript: String, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard config != nil else {
            completion(.failure(GatewayError.missingConfiguration))
            return nil
        }
        guard authState == .signedIn, accessToken != nil else {
            completion(.failure(GatewayError.notSignedIn))
            return nil
        }

        // Proactive refresh - see file header/section 9 of the M0 spec.
        // NOTE (disclosed limitation, acceptable for STEP 1): while this
        // proactive refresh is in flight, this method returns nil rather
        // than a live URLSessionDataTask, so a barge-in landing in that
        // narrow window cannot .cancel() a task that doesn't exist yet.
        // Correctness is still fully protected by JVConversationController's
        // existing turnGeneration check on the eventual completion - only
        // immediate cancellation (not correctness) is affected, and only
        // during this brief refresh window, not during the actual gateway
        // request itself (which IS a cancellable task, returned normally).
        if let expiresAt, expiresAt.timeIntervalSinceNow < 60 {
            log("JointVibeGateway: access token near expiry - refreshing before this turn")
            refreshIfPossible { [weak self] success in
                guard let self else { return }
                guard success else {
                    completion(.failure(GatewayError.silentAuthenticationFailure))
                    return
                }
                self.performRequest(transcript: transcript, clientTurnID: UUID().uuidString, isRetryAfterAuthFailure: false, completion: completion)
            }
            return nil
        }

        return performRequest(transcript: transcript, clientTurnID: UUID().uuidString, isRetryAfterAuthFailure: false, completion: completion)
    }

    @discardableResult
    private func performRequest(transcript: String, clientTurnID: String, isRetryAfterAuthFailure: Bool, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard let config, let accessToken else {
            completion(.failure(GatewayError.notSignedIn))
            return nil
        }

        // Only append the user turn to local history once we're actually
        // about to send it - a retry after a -1 result re-sends the SAME
        // transcript, so we must not double-append it (the retry call
        // path below removes-then-lets-this-readd, see the -1 branch).
        conversation.append(["role": "user", "content": transcript])

        var request = URLRequest(url: config.supabaseURL.appendingPathComponent("functions/v1/ai-gateway"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        var body: [String: Any] = [
            "mode": "customer",
            "surface": "glasses",
            "client_turn_id": clientTurnID,
            "surface_options": [
                "max_words": 60,
                "no_markdown": true,
                "spoken_style": true
            ],
            "messages": conversation
        ]
        if let sessionID {
            body["session_id"] = sessionID
        }
        // user_lat/user_lng deliberately omitted - not available in this
        // harness, and explicitly not to be invented (M0 spec section 4).

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            conversation.removeLast()
            completion(.failure(GatewayError.invalidResponse))
            return nil
        }
        request.httpBody = bodyData

        let requestSentDate = Date()
        log("JointVibeGateway: ai-gateway request sent (client_turn_id=\(clientTurnID), retry=\(isRetryAfterAuthFailure), session_id=\(sessionID ?? "none yet"))")
        onLatencyCheckpoint?("jvGatewayRequestSent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let elapsedSeconds = Date().timeIntervalSince(requestSentDate)
            DispatchQueue.main.async {
                self.handleGatewayResponse(
                    data: data, response: response, error: error,
                    elapsedSeconds: elapsedSeconds,
                    transcript: transcript, clientTurnID: clientTurnID,
                    isRetryAfterAuthFailure: isRetryAfterAuthFailure,
                    completion: completion
                )
            }
        }
        task.resume()
        return task
    }

    private func handleGatewayResponse(
        data: Data?, response: URLResponse?, error: Error?,
        elapsedSeconds: TimeInterval,
        transcript: String, clientTurnID: String, isRetryAfterAuthFailure: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if let error {
            log("JointVibeGateway: request FAILED after \(String(format: "%.2f", elapsedSeconds))s: \(error.localizedDescription)")
            conversation.removeLast()
            completion(.failure(error))
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            conversation.removeLast()
            completion(.failure(GatewayError.invalidResponse))
            return
        }

        let statusCode = httpResponse.statusCode
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let sessionIdHeader = httpResponse.value(forHTTPHeaderField: "X-Session-Id")
        let intentHeader = httpResponse.value(forHTTPHeaderField: "X-Intent")
        let remainingTokensHeader = httpResponse.value(forHTTPHeaderField: "X-Remaining-Tokens")

        log("JointVibeGateway: response HTTP \(statusCode) Content-Type=\(contentType) X-Session-Id=\(sessionIdHeader ?? "none") X-Intent=\(intentHeader ?? "none") X-Remaining-Tokens=\(remainingTokensHeader ?? "none") elapsed=\(String(format: "%.2f", elapsedSeconds))s client_turn_id=\(clientTurnID)")

        lastIntent = intentHeader
        lastRemainingTokens = remainingTokensHeader
        if let sessionIdHeader, !sessionIdHeader.isEmpty {
            sessionID = sessionIdHeader
            lastSessionID = sessionIdHeader
        }

        // Branch on Content-Type first, per explicit instruction - never
        // assume every response is SSE just because the status is 200.
        guard contentType.contains("text/event-stream") else {
            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
            log("JointVibeGateway: non-SSE response body: \(bodyText)")
            conversation.removeLast()
            switch statusCode {
            case 429:
                completion(.failure(GatewayError.quotaOrRateLimited))
            case 402:
                completion(.failure(GatewayError.paymentRequired))
            default:
                completion(.failure(GatewayError.httpError(statusCode)))
            }
            return
        }

        guard statusCode == 200, let data, let accumulated = Self.parseSSEBody(data), !accumulated.isEmpty else {
            conversation.removeLast()
            completion(.failure(GatewayError.invalidResponse))
            return
        }

        log("RAW JV RESPONSE: \(accumulated)")

        // Silent-anonymous-fallback detection - see file header.
        if remainingTokensHeader == "-1" {
            conversation.removeLast() // will be re-added by the retry, or discarded entirely on final failure
            if isRetryAfterAuthFailure {
                log("JointVibeGateway: X-Remaining-Tokens == -1 persisted after refresh+retry - AUTH FAILURE, stopping turn")
                authState = .requiresSignIn(reason: "silent anonymous fallback")
                completion(.failure(GatewayError.silentAuthenticationFailure))
                return
            }
            log("JointVibeGateway: X-Remaining-Tokens == -1 - refreshing once and retrying this turn (same client_turn_id)")
            refreshIfPossible { [weak self] success in
                guard let self else { return }
                guard success else {
                    self.authState = .requiresSignIn(reason: "silent anonymous fallback, refresh failed")
                    completion(.failure(GatewayError.silentAuthenticationFailure))
                    return
                }
                self.performRequest(transcript: transcript, clientTurnID: clientTurnID, isRetryAfterAuthFailure: true, completion: completion)
            }
            return
        }

        let spoken = Self.sanitizeForSpeech(accumulated)
        log("SPOKEN JV RESPONSE: \(spoken)")
        conversation.append(["role": "assistant", "content": spoken])
        onLatencyCheckpoint?("jvGatewayResponseComplete")
        completion(.success(spoken))
    }

    // MARK: - SSE body parsing (buffered - STEP 1 scope only, see file
    // header). Operates on the complete response Data, not incremental
    // network chunks - STEP 2's true incremental parser is a separate,
    // future addition, not built here.

    private static func parseSSEBody(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var accumulated = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue } // SSE comment line
            guard line.hasPrefix("data:") else { continue }
            let jsonPart = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if jsonPart == "[DONE]" { break }
            guard let jsonData = jsonPart.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let content = delta["content"] as? String
            else {
                continue // malformed/unrecognized frame - skip, never crash (project-wide convention)
            }
            accumulated += content
        }
        return accumulated
    }

    // MARK: - Narrow spoken-text sanitizer (per explicit "narrow,
    // defensive, do not redesign gateway formatting" instruction).
    // Strips only clearly-non-spoken structured payload markers; leaves
    // ordinary conversational language untouched.

    private static func sanitizeForSpeech(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"\[EMO=[^\]]*\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"```[a-zA-Z]*\n?[\s\S]*?```"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[MENU_DATA\][\s\S]*?\[/MENU_DATA\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[VENUE_DATA\][\s\S]*?\[/VENUE_DATA\]"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
