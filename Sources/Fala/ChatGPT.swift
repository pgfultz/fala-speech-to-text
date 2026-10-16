import Foundation

/// Reads and refreshes the ChatGPT OAuth session that the Codex CLI stores in ~/.codex/auth.json.
/// Refreshed tokens are written back so Codex keeps working with the same session.
actor CodexAuth {
    static let shared = CodexAuth()

    struct Session {
        var accessToken: String
        var accountId: String?
    }

    struct Profile: Equatable {
        var email: String?
        var plan: String?
    }

    enum AuthError: LocalizedError {
        case notLoggedIn, apiKeyOnly, refreshFailed(String)
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: tr("Sign in to ChatGPT", "Faça login no ChatGPT")
            case .apiKeyOnly: tr("Codex is using an API key — sign in with ChatGPT", "O Codex está usando chave de API — faça login com ChatGPT")
            case .refreshFailed(let m): tr("Session expired — sign in again (\(m))", "Sessão expirada — faça login novamente (\(m))")
            }
        }
    }

    private static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var authFile: URL { codexHome.appendingPathComponent("auth.json") }

    /// Synchronous, cheap check used by the UI.
    nonisolated static func profile() -> Profile? {
        guard let json = try? readJSON(), let tokens = json["tokens"] as? [String: Any],
              tokens["access_token"] is String else { return nil }
        let claims = (tokens["id_token"] as? String).flatMap(decodeJWT) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return Profile(email: claims["email"] as? String, plan: auth?["chatgpt_plan_type"] as? String)
    }

    func session() async throws -> Session {
        let json = try Self.readJSON()
        guard let tokens = json["tokens"] as? [String: Any], let access = tokens["access_token"] as? String else {
            throw json["OPENAI_API_KEY"] is String ? AuthError.apiKeyOnly : AuthError.notLoggedIn
        }
        let exp = (Self.decodeJWT(access)?["exp"] as? Double) ?? .greatestFiniteMagnitude
        if exp - 60 < Date().timeIntervalSince1970 {
            return try await refresh()
        }
        return Session(accessToken: access, accountId: tokens["account_id"] as? String)
    }

    func refresh() async throws -> Session {
        var json = try Self.readJSON()
        guard var tokens = json["tokens"] as? [String: Any], let refresh = tokens["refresh_token"] as? String else {
            throw AuthError.notLoggedIn
        }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": "openid profile email",
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String else {
            throw AuthError.refreshFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        tokens["access_token"] = access
        if let v = body["id_token"] as? String { tokens["id_token"] = v }
        if let v = body["refresh_token"] as? String { tokens["refresh_token"] = v }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: .now)
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: Self.authFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.authFile.path)
        return Session(accessToken: access, accountId: tokens["account_id"] as? String)
    }

    private static func readJSON() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: authFile),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuthError.notLoggedIn }
        return json
    }

    private static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Transcribes audio with the same endpoint ChatGPT/Codex dictation uses, billed to the subscription.
enum ChatGPTTranscriber {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    enum TranscribeError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(429, _): tr("Usage limit reached", "Limite de uso atingido")
            case .http(400, let m) where m.contains("too_short"): tr("Audio too short", "Áudio muito curto")
            case .http(let code, let body): tr("Transcription failed (HTTP \(code))", "Falha na transcrição (HTTP \(code))") + (ProcessInfo.processInfo.arguments.contains("--transcribe") ? " \(body.prefix(300))" : "")
            }
        }
    }

    static func transcribe(wav: Data, language: String) async throws -> String {
        var auth = try await CodexAuth.shared.session()
        for attempt in 0..<2 {
            let boundary = "fala-\(UUID().uuidString)"
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
            if let account = auth.accountId { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = multipart(boundary: boundary, wav: wav, language: language == "auto" ? nil : language)

            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                auth = try await CodexAuth.shared.refresh()
                continue
            }
            guard status == 200 else {
                throw TranscribeError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((body?["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw CodexAuth.AuthError.notLoggedIn
    }

    private static func multipart(boundary: String, wav: Data, language: String?) -> Data {
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"fala.wav\"")
        line("Content-Type: audio/wav")
        line("")
        body.append(wav)
        line("")
        if let language {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"language\"")
            line("")
            line(language)
        }
        line("--\(boundary)--")
        return body
    }
}
