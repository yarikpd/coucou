#if !APPSTORE
import SwiftUI

// MARK: - Codex plan usage

struct CodexPlanUsage {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var resetCredits: Int?         // free full resets available
    var resetCreditExpiresAt: Date? // soonest expiry among them
    var planType: String?
    var updatedAt: Date

    var planUsage: PlanUsage { PlanUsage(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt) }
}

// MARK: - Fetching (codex app-server, the source behind Codex's /status)

enum CodexPlanGauge {

    static func codexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
        ]
        // nvm: one bin folder per Node version, newest first.
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/codex" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `codex app-server` and asks for `account/rateLimits/read`. nil if Codex is missing or not signed in.
    static func fetch() async -> CodexPlanUsage? {
        guard let codex = codexExecutable() else { return nil }
        return await Task.detached { readRateLimits(codex: codex) }.value
    }

    private static func readRateLimits(codex: String) -> CodexPlanUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: codex).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Give up after 15 s: terminating closes stdout, which ends the read loop.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"coucou","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["id"] as? Int == 2 else { continue }
                return (obj["result"] as? [String: Any]).flatMap(parse)
            }
        }
    }

    /// Parses an `account/rateLimits/read` result.
    static func parse(result: [String: Any]) -> CodexPlanUsage? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var usage = CodexPlanUsage(planType: limits["planType"] as? String, updatedAt: Date())
        // primary/secondary are not fixed to a window: sort them by duration
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["usedPercent"] as? Double,
                  let resetsAt = w["resetsAt"] as? Double else { continue }
            let window = PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: Date(timeIntervalSince1970: resetsAt))
            if let mins = w["windowDurationMins"] as? Int, mins <= 24 * 60 {
                usage.fiveHour = window
            } else {
                usage.sevenDay = window
            }
        }
        if let resets = result["rateLimitResetCredits"] as? [String: Any] {
            usage.resetCredits = resets["availableCount"] as? Int
            let expiries = (resets["credits"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String == "available" }
                .compactMap { $0["expiresAt"] as? Double }
            usage.resetCreditExpiresAt = expiries.min().map { Date(timeIntervalSince1970: $0) }
        }
        guard usage.fiveHour != nil || usage.sevenDay != nil else { return nil }
        return usage
    }

    static func pillLabel(_ usage: CodexPlanUsage?) -> String {
        guard let usage, let pct = ClaudePlanGauge.dominantPct(usage.planUsage) else { return "Codex —" }
        return "Codex \(Int(pct.rounded()))%"
    }

    static func color(_ usage: CodexPlanUsage?) -> String {
        ClaudePlanGauge.color(for: usage.flatMap { ClaudePlanGauge.dominantPct($0.planUsage) })
    }
}

// MARK: - Codex Plan Card View

private let resetExpiryFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "MMM d"
    return fmt
}()

struct CodexPlanCardView: View {
    let usage: CodexPlanUsage?   // nil = loading or unavailable

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: CodexPlanGauge.color(usage)))
                    .frame(width: 7, height: 7)
                Text("Codex plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                PlanProviderSwitcher()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 12)

            // Gauge rows
            VStack(alignment: .leading, spacing: 5) {
                if usage?.fiveHour != nil {
                    GaugeRowView(label: String(localized: "plan.5hours"), window: usage?.fiveHour, now: now)
                }
                GaugeRowView(label: String(localized: "plan.week"), window: usage?.sevenDay, now: now, weekly: true)
                HStack(spacing: 5) {
                    Text("Resets")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 52, alignment: .leading)
                    Text(resetsText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Update countdown every 30s, only while visible
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return "Asking Codex…" }
        let plan = usage.planType.map { "\($0) · " } ?? ""
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return plan + "just now" }
        let mins = Int(diff / 60)
        if mins < 60 { return plan + "\(mins) min ago" }
        return plan + "\(mins / 60) h ago"
    }

    private var resetsText: String {
        guard let count = usage?.resetCredits else { return "—" }
        var text = "\(count) available"
        if count > 0, let exp = usage?.resetCreditExpiresAt {
            text += " · until \(resetExpiryFormatter.string(from: exp))"
        }
        return text
    }
}

// MARK: - Plan Detail Provider & Switcher

enum PlanDetailProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case antigravity

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "AGY"
        }
    }
}

struct PlanProviderSwitcher: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let providers = state.enabledPlanProviders
        if providers.count > 1 {
            HStack(spacing: 3) {
                ForEach(providers) { provider in
                    let isSelected = state.activePlanPillProvider == provider
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            state.planDetailProvider = provider
                        }
                        switch provider {
                        case .claude: break
                        case .codex: state.refreshCodexPlanUsage()
                        case .antigravity: state.refreshAntigravityPlanUsage()
                        }
                    }) {
                        Text(provider.shortTitle)
                            .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Antigravity plan usage

struct AntigravityPlanUsage {
    var fiveHour: PlanWindow?          // Gemini 5-hour window
    var sevenDay: PlanWindow?          // Gemini weekly window
    var claudeGptFiveHour: PlanWindow? // Claude & GPT 5-hour window
    var claudeGptSevenDay: PlanWindow? // Claude & GPT weekly window
    var planType: String?
    var updatedAt: Date

    var planUsage: PlanUsage {
        PlanUsage(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt)
    }

    var claudeGptDominantWindow: PlanWindow? {
        switch (claudeGptFiveHour, claudeGptSevenDay) {
        case (nil, nil): return nil
        case (let f?, nil): return f
        case (nil, let w?): return w
        case (let f?, let w?):
            return ClaudePlanGauge.effectivePct(f) >= ClaudePlanGauge.effectivePct(w) ? f : w
        }
    }

    var claudeGptIsWeeklyDominant: Bool {
        guard let dom = claudeGptDominantWindow, let w = claudeGptSevenDay else { return false }
        return dom == w
    }

    var dominantPct: Double? {
        let p1 = ClaudePlanGauge.dominantPct(planUsage)
        let p2 = claudeGptDominantWindow.map { ClaudePlanGauge.effectivePct($0) }
        switch (p1, p2) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }
}

// MARK: - Antigravity Plan Gauge (local language_server Connect-RPC + agy CLI fallback)

private final class LocalhostCertDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum AntigravityPlanGauge {

    private struct ServerCandidate: Sendable {
        let pid: Int
        let csrfToken: String
        let ports: [Int]
        let isApp: Bool
    }

    private static let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg, delegate: LocalhostCertDelegate(), delegateQueue: nil)
    }()

    static func fetch() async -> AntigravityPlanUsage? {
        let candidates = await Task.detached { discoverLocalServers() }.value
        for candidate in candidates {
            for port in candidate.ports {
                if let usage = await queryLocalServer(port: port, csrfToken: candidate.csrfToken) {
                    return usage
                }
            }
        }
        if let agy = agyExecutable() {
            return await Task.detached { readViaAgyCLI(agy: agy) }.value
        }
        return nil
    }

    private static func discoverLocalServers() -> [ServerCandidate] {
        guard let psOutput = runCommand("/bin/ps", arguments: ["-ax", "-o", "pid=,command="]) else {
            return []
        }

        var rawCandidates: [(pid: Int, csrfToken: String, isApp: Bool)] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.contains("language_server") || trimmed.contains("language-server") else { continue }
            guard trimmed.localizedCaseInsensitiveContains("antigravity") || trimmed.contains("--csrf_token") else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1])

            guard let token = extractCsrfToken(from: cmd), !token.isEmpty else { continue }
            let isApp = cmd.contains("Antigravity.app")
                || cmd.contains("--subclient_type hub")
                || cmd.contains("--app_data_dir antigravity ")
            rawCandidates.append((pid: pid, csrfToken: token, isApp: isApp))
        }

        rawCandidates.sort { $0.isApp && !$1.isApp }

        var results: [ServerCandidate] = []
        for item in rawCandidates {
            let ports = listeningPorts(forPid: item.pid)
            if !ports.isEmpty {
                results.append(ServerCandidate(pid: item.pid, csrfToken: item.csrfToken, ports: ports, isApp: item.isApp))
            }
        }
        return results
    }

    private static func extractCsrfToken(from command: String) -> String? {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (idx, tok) in tokens.enumerated() {
            if tok == "--csrf_token", idx + 1 < tokens.count {
                return tokens[idx + 1]
            }
            if tok.hasPrefix("--csrf_token=") {
                return String(tok.dropFirst("--csrf_token=".count))
            }
        }
        return nil
    }

    private static func listeningPorts(forPid pid: Int) -> [Int] {
        guard let out = runCommand("/usr/sbin/lsof", arguments: ["-a", "-nP", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)"]) else {
            return []
        }
        var ports: [Int] = []
        for line in out.split(separator: "\n") {
            // Example: language_ 67439 user 8u IPv4 ... TCP 127.0.0.1:54548 (LISTEN)
            guard line.contains("(LISTEN)") else { continue }
            if let colonIdx = line.lastIndex(of: ":") {
                let afterColon = line[line.index(after: colonIdx)...]
                if let spaceIdx = afterColon.firstIndex(where: { $0.isWhitespace }),
                   let port = Int(afterColon[..<spaceIdx]),
                   !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        // Prefer higher port first (in Antigravity, HTTP is usually the second port, HTTPS is first)
        return ports.sorted(by: >)
    }

    private static func runCommand(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func queryLocalServer(port: Int, csrfToken: String) async -> AntigravityPlanUsage? {
        for scheme in ["http", "https"] {
            let summaryDict = await postConnectRPC(
                scheme: scheme,
                port: port,
                path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                csrfToken: csrfToken
            )
            let statusDict = await postConnectRPC(
                scheme: scheme,
                port: port,
                path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
                csrfToken: csrfToken
            )

            if summaryDict != nil || statusDict != nil {
                if let usage = parseCombined(summary: summaryDict, userStatusRoot: statusDict) {
                    return usage
                }
            }
        }
        return nil
    }

    private static func postConnectRPC(scheme: String, port: Int, path: String, csrfToken: String) async -> [String: Any]? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func parseCombined(summary: [String: Any]?, userStatusRoot: [String: Any]?) -> AntigravityPlanUsage? {
        var usage = AntigravityPlanUsage(updatedAt: Date())

        // 1. Extract plan tier from GetUserStatus if available
        if let us = userStatusRoot?["userStatus"] as? [String: Any] {
            if let tierName = (us["userTier"] as? [String: Any])?["name"] as? String, !tierName.isEmpty {
                usage.planType = tierName
            } else if let planName = ((us["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String, !planName.isEmpty {
                usage.planType = planName
            }
        }

        // 2. Parse RetrieveUserQuotaSummary groups & buckets
        if let summary {
            let root = (summary["response"] as? [String: Any]) ?? summary
            if let groups = root["groups"] as? [[String: Any]] {
                for group in groups {
                    let groupName = (group["displayName"] as? String ?? "").lowercased()
                    let isThreeP = groupName.contains("claude") || groupName.contains("gpt")
                    let buckets = group["buckets"] as? [[String: Any]] ?? []
                    for bucket in buckets {
                        guard let window = parseBucketWindow(bucket) else { continue }
                        let bucketId = (bucket["bucketId"] as? String ?? "").lowercased()
                        let winType = (bucket["window"] as? String ?? "").lowercased()
                        let isWeekly = winType == "weekly" || bucketId.contains("weekly")
                        let bucketIs3P = isThreeP || bucketId.contains("3p")

                        if bucketIs3P {
                            if isWeekly { usage.claudeGptSevenDay = window }
                            else { usage.claudeGptFiveHour = window }
                        } else {
                            if isWeekly { usage.sevenDay = window }
                            else { usage.fiveHour = window }
                        }
                    }
                }
            }
        }

        // 3. Fallback to GetUserStatus clientModelConfigs if RetrieveUserQuotaSummary had no buckets
        if usage.fiveHour == nil && usage.sevenDay == nil,
           let us = userStatusRoot?["userStatus"] as? [String: Any],
           let cmcd = us["cascadeModelConfigData"] as? [String: Any],
           let configs = cmcd["clientModelConfigs"] as? [[String: Any]] {
            for cfg in configs {
                let label = (cfg["label"] as? String ?? "").lowercased()
                let modelId = (cfg["modelId"] as? String ?? "").lowercased()
                guard let qInfo = cfg["quotaInfo"] as? [String: Any],
                      let win = parseBucketWindow(qInfo) else { continue }
                if label.contains("gemini") || modelId.contains("gemini") {
                    if usage.fiveHour == nil || ClaudePlanGauge.effectivePct(win) > ClaudePlanGauge.effectivePct(usage.fiveHour!) {
                        usage.fiveHour = win
                    }
                } else if label.contains("claude") || label.contains("gpt") || modelId.contains("claude") || modelId.contains("gpt") {
                    if usage.claudeGptFiveHour == nil || ClaudePlanGauge.effectivePct(win) > ClaudePlanGauge.effectivePct(usage.claudeGptFiveHour!) {
                        usage.claudeGptFiveHour = win
                    }
                }
            }
        }

        guard usage.fiveHour != nil || usage.sevenDay != nil || usage.claudeGptFiveHour != nil || usage.claudeGptSevenDay != nil else {
            return nil
        }
        return usage
    }

    private static func parseBucketWindow(_ dict: [String: Any]) -> PlanWindow? {
        guard let resetStr = dict["resetTime"] as? String,
              let resetsAt = parseISO8601(resetStr) else {
            return nil
        }
        let remaining: Double
        if let num = dict["remainingFraction"] as? NSNumber {
            remaining = num.doubleValue
        } else {
            // In proto3 JSON, 0.0 is omitted by default
            remaining = 0.0
        }
        let usedPct = min(100.0, max(0.0, (1.0 - remaining) * 100.0))
        return PlanWindow(usedPct: usedPct, resetsAt: resetsAt)
    }

    private static func parseISO8601(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    // MARK: - agy CLI fallback

    static func agyExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/bin/agy"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func readViaAgyCLI(agy: String) -> AntigravityPlanUsage? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agy)
        proc.arguments = ["-p", "/usage", "--output-format", "json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let timeout = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseCombined(summary: obj, userStatusRoot: nil)
    }

    // MARK: - Display helpers

    static func pillLabel(_ usage: AntigravityPlanUsage?) -> String {
        guard let usage, let pct = usage.dominantPct else { return "Antigravity —" }
        return "Antigravity \(Int(pct.rounded()))%"
    }

    static var brandColor: String {
        PillCatalog.definition(for: "agent_antigravity")?.color ?? "#E879F9"
    }

    static func color(_ usage: AntigravityPlanUsage?) -> String {
        let baseColor = brandColor
        guard let pct = usage?.dominantPct else { return baseColor }
        if pct >= 75 { return "#F4505E" }   // red — critical
        if pct >= 50 { return "#F5A524" }   // amber — warning
        return baseColor                    // Antigravity purple
    }
}

// MARK: - Antigravity Plan Card View

struct AntigravityPlanCardView: View {
    let usage: AntigravityPlanUsage?

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: AntigravityPlanGauge.brandColor))
                    .frame(width: 7, height: 7)
                Text("Antigravity plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                PlanProviderSwitcher()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 12)

            // Gauge rows
            VStack(alignment: .leading, spacing: 5) {
                GaugeRowView(label: String(localized: "plan.5hours"), window: usage?.fiveHour, now: now)
                GaugeRowView(label: String(localized: "plan.week"), window: usage?.sevenDay, now: now, weekly: true)
                if let threeP = usage?.claudeGptDominantWindow {
                    GaugeRowView(
                        label: "Claude",
                        window: threeP,
                        now: now,
                        weekly: usage?.claudeGptIsWeeklyDominant ?? false
                    )
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return "Asking Antigravity…" }
        let plan = usage.planType.map { "\($0) · " } ?? ""
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return plan + String(localized: "plan.just-now") }
        let mins = Int(diff / 60)
        if mins < 60 { return plan + String(format: String(localized: "plan.mins-ago %lld"), Int64(mins)) }
        return plan + String(format: String(localized: "plan.hours-ago %lld"), Int64(mins / 60))
    }
}
#endif
