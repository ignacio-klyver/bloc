import Foundation

/// Where the notes go and with what credentials.
///
/// The scheduling itself is Slack's job, not Bloc's: a note handed to `chat.scheduleMessage`
/// is held on Slack's servers and delivered at its hour whether or not this Mac is awake,
/// online, or even switched on. A timer inside a status-bar app could promise none of that.
struct SlackConfig: Codable, Equatable {
    /// A bot token (`xoxb-…`) or a user token (`xoxp-…`).
    var token: String
    /// The conversation the notes land in: a `D…` for the direct message Bloc opens with
    /// you, or a `C…` when a channel was chosen instead.
    var channel: String
    /// What to call that conversation out loud: `@juan`, `#growth`.
    var label: String
}

// MARK: - Storage

/// The token on disk, in Application Support rather than in the notes folder: the notes
/// folder is the user's, meant to be read, edited and synced, and a credential has no
/// business travelling with it.
///
/// The file is written `0600` inside a `0700` directory, the same posture `gh` and `aws`
/// take with their credentials. The Keychain would be stricter, but its access control is
/// bound to the code signature, and Bloc is ad-hoc signed: every rebuild changes the
/// identity and the app would have to ask for the item back each time.
enum SlackStore {

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bloc", isDirectory: true)
    }

    static var fileURL: URL { folder.appendingPathComponent("slack.json") }

    static func load() -> SlackConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SlackConfig.self, from: data)
    }

    static func save(_ config: SlackConfig) throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = try JSONEncoder().encode(config)
        // Write through FileManager so the permissions land with the file rather than a
        // moment after it, which would leave the token world-readable in between.
        try? FileManager.default.removeItem(at: fileURL)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw SlackError.storage
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Errors

enum SlackError: LocalizedError, Equatable {
    /// Slack answered, and said no.
    case api(String)
    /// Slack never answered.
    case transport(String)
    case storage
    case notConnected

    var errorDescription: String? {
        switch self {
        case .api(let code): return SlackError.spanish(code)
        case .transport(let detail): return "no se pudo hablar con Slack: \(detail)"
        case .storage: return "no se pudo guardar la configuración de Slack"
        case .notConnected: return "Slack no está conectado"
        }
    }

    /// Slack's error codes, said out loud. Anything unmapped is passed through verbatim
    /// rather than flattened into a generic failure: the code is what makes it searchable.
    private static func spanish(_ code: String) -> String {
        switch code {
        case "invalid_auth", "not_authed", "account_inactive", "token_revoked":
            return "el token no sirve o fue revocado. Reconectá con Bloc --slack-connect"
        case "missing_scope", "not_allowed_token_type":
            return "al token le faltan permisos (chat:write, im:write, users:read.email)"
        case "time_in_past":
            return "esa hora ya pasó"
        case "time_too_far":
            return "Slack no agenda más allá de 120 días"
        case "channel_not_found":
            return "no encuentro esa conversación"
        case "not_in_channel":
            return "la app no está en ese canal. Invitala con /invite"
        case "users_not_found":
            return "no encontré a esa persona en el workspace"
        case "ratelimited", "rate_limited":
            return "Slack está limitando los pedidos, probá de nuevo en un rato"
        case "msg_too_long":
            return "la nota es demasiado larga para un mensaje de Slack"
        default:
            return "Slack rechazó el pedido: \(code)"
        }
    }
}

// MARK: - API

/// The four calls Bloc needs, spoken to over plain HTTP. No SDK: the surface is small enough
/// that a dependency would cost more than it saves, and this keeps the build a single
/// `swift build` with nothing to fetch.
enum SlackAPI {

    private static let base = URL(string: "https://slack.com/api/")!

    private static func call(_ method: String, token: String,
                             body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: method, relativeTo: base) else {
            throw SlackError.transport("método inválido")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SlackError.transport(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.transport("respuesta ilegible")
        }
        guard json["ok"] as? Bool == true else {
            throw SlackError.api(json["error"] as? String ?? "desconocido")
        }
        return json
    }

    struct Identity {
        var userID: String
        var user: String
        var team: String
        /// Bot tokens act as the app, so they cannot know which human to write to.
        var isBot: Bool
    }

    static func authTest(token: String) async throws -> Identity {
        let json = try await call("auth.test", token: token, body: [:])
        return Identity(userID: json["user_id"] as? String ?? "",
                        user: json["user"] as? String ?? "",
                        team: json["team"] as? String ?? "",
                        isBot: json["bot_id"] != nil)
    }

    static func lookupByEmail(_ email: String, token: String) async throws -> String {
        // The only call Slack still wants form-encoded arguments for.
        guard var components = URLComponents(string: "https://slack.com/api/users.lookupByEmail") else {
            throw SlackError.transport("URL inválida")
        }
        components.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components.url else { throw SlackError.transport("URL inválida") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SlackError.transport(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.transport("respuesta ilegible")
        }
        guard json["ok"] as? Bool == true else {
            throw SlackError.api(json["error"] as? String ?? "desconocido")
        }
        guard let user = json["user"] as? [String: Any], let id = user["id"] as? String else {
            throw SlackError.transport("Slack no devolvió el usuario")
        }
        return id
    }

    /// Resolves the direct-message conversation with a person, creating it if needed.
    static func openDM(userID: String, token: String) async throws -> String {
        let json = try await call("conversations.open", token: token, body: ["users": userID])
        guard let channel = json["channel"] as? [String: Any],
              let id = channel["id"] as? String else {
            throw SlackError.transport("Slack no devolvió la conversación")
        }
        return id
    }

    /// Hands the message to Slack to deliver at `date`. Returns Slack's id for it, which is
    /// the only handle there is for calling it off later.
    static func schedule(text: String, at date: Date, config: SlackConfig) async throws -> String {
        let json = try await call("chat.scheduleMessage", token: config.token, body: [
            "channel": config.channel,
            "post_at": Int(date.timeIntervalSince1970),
            "text": text,
        ])
        guard let id = json["scheduled_message_id"] as? String else {
            throw SlackError.transport("Slack no devolvió el id del mensaje")
        }
        return id
    }

    static func cancel(id: String, config: SlackConfig) async throws {
        _ = try await call("chat.deleteScheduledMessage", token: config.token, body: [
            "channel": config.channel,
            "scheduled_message_id": id,
        ])
    }

    static func post(text: String, config: SlackConfig) async throws {
        _ = try await call("chat.postMessage", token: config.token, body: [
            "channel": config.channel,
            "text": text,
        ])
    }

    struct Scheduled {
        var id: String
        var postAt: Date
        var text: String
    }

    static func pending(config: SlackConfig) async throws -> [Scheduled] {
        let json = try await call("chat.scheduledMessages.list", token: config.token,
                                  body: ["channel": config.channel, "limit": 100])
        let raw = json["scheduled_messages"] as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let id = item["id"] as? String,
                  let at = item["post_at"] as? Int else { return nil }
            return Scheduled(id: id,
                             postAt: Date(timeIntervalSince1970: TimeInterval(at)),
                             text: item["text"] as? String ?? "")
        }
        .sorted { $0.postAt < $1.postAt }
    }
}

// MARK: - Command line setup

/// Connecting is a one-off, so it lives on the command line instead of costing the panel a
/// settings screen it would show once and then carry forever.
enum SlackSetup {

    /// Runs an async call from the synchronous command-line entry point. URLSession answers
    /// on its own queue, so blocking the caller here cannot deadlock it.
    private static func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = Box<Result<T, Error>>(.failure(SlackError.transport("sin respuesta")))
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await operation()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func fail(_ message: String) -> Int32 {
        print("✗ \(message)")
        return 1
    }

    /// `Bloc --slack-connect <token> [--to <email | U… | C… | #canal>]`
    static func connect(token: String, destination: String?) -> Int32 {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("falta el token") }

        print("… verificando el token")
        let identity: SlackAPI.Identity
        switch blocking({ try await SlackAPI.authTest(token: trimmed) }) {
        case .success(let value): identity = value
        case .failure(let error): return fail(error.localizedDescription)
        }
        print("  workspace: \(identity.team)")

        // A user token already knows who you are. A bot token acts as the app, so the
        // person to write to has to be named.
        let target = destination ?? (identity.isBot ? nil : identity.userID)
        guard let target else {
            print("✗ el token es de bot, así que no sabe a quién escribirte.")
            print("  volvé a correrlo agregando tu mail de Slack:")
            print("    Bloc --slack-connect \(trimmed.prefix(12))… --to vos@empresa.com")
            return 1
        }

        let resolved: (channel: String, label: String)
        switch blocking({ try await resolveDestination(target, token: trimmed) }) {
        case .success(let value): resolved = value
        case .failure(let error): return fail(error.localizedDescription)
        }

        let config = SlackConfig(token: trimmed, channel: resolved.channel, label: resolved.label)
        do {
            try SlackStore.save(config)
        } catch {
            return fail(error.localizedDescription)
        }

        print("✓ conectado. Las notas agendadas van a \(resolved.label).")
        print("  el token quedó en \(SlackStore.fileURL.path) (solo lo lee tu usuario)")
        print("  probalo con:  Bloc --slack-test")
        return 0
    }

    /// Accepts a mail, a member id, a conversation id or a channel name, and comes back with
    /// something `chat.scheduleMessage` will take.
    private static func resolveDestination(_ raw: String,
                                           token: String) async throws -> (String, String) {
        if raw.contains("@"), raw.contains(".") {
            let id = try await SlackAPI.lookupByEmail(raw, token: token)
            return (try await SlackAPI.openDM(userID: id, token: token), raw)
        }
        if raw.hasPrefix("U") || raw.hasPrefix("W") {
            return (try await SlackAPI.openDM(userID: raw, token: token), "tu DM")
        }
        if raw.hasPrefix("#") {
            return (String(raw.dropFirst()), raw)
        }
        // Already a conversation id (C…, D…, G…).
        return (raw, raw)
    }

    static func status() -> Int32 {
        guard let config = SlackStore.load() else {
            print("Slack no está conectado.")
            print("  Bloc --slack-connect xoxb-… --to vos@empresa.com")
            return 0
        }
        print("Slack conectado")
        print("  destino: \(config.label) (\(config.channel))")
        print("  token:   \(config.token.prefix(12))…")
        print("  archivo: \(SlackStore.fileURL.path)")
        return 0
    }

    static func test() -> Int32 {
        guard let config = SlackStore.load() else {
            return fail("Slack no está conectado. Corré Bloc --slack-connect primero.")
        }
        switch blocking({ try await SlackAPI.post(text: "Bloc quedó conectado ✅", config: config) }) {
        case .success:
            print("✓ mensaje enviado a \(config.label)")
            return 0
        case .failure(let error):
            return fail(error.localizedDescription)
        }
    }

    static func pending() -> Int32 {
        guard let config = SlackStore.load() else {
            return fail("Slack no está conectado.")
        }
        switch blocking({ try await SlackAPI.pending(config: config) }) {
        case .success(let messages):
            guard !messages.isEmpty else {
                print("no hay nada agendado en \(config.label).")
                return 0
            }
            print("agendado en \(config.label):")
            for message in messages {
                print("  \(When.label(message.postAt))  \(message.text)")
            }
            return 0
        case .failure(let error):
            return fail(error.localizedDescription)
        }
    }

    static func disconnect() -> Int32 {
        SlackStore.clear()
        print("✓ Slack desconectado. Borré el token de \(SlackStore.fileURL.path).")
        print("  los mensajes ya agendados siguen en Slack; cancelalos desde ahí si hace falta.")
        return 0
    }
}
