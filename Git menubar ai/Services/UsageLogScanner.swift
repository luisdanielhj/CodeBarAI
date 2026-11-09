import Darwin
import Foundation

/// Reads token usage from the session logs Claude Code and Codex keep on disk.
///
/// The logs are append-only JSONL files and can add up to gigabytes, so each
/// file is parsed once and then only from where the last scan stopped. The
/// parsed counts are cached in Application Support. Prompt and response
/// content is never kept: lines are filtered by byte search before parsing,
/// and only model names, timestamps and token counts are extracted.
actor UsageLogScanner {
    /// Covers the longest period shown, plus a day for time zone edges.
    static let retention: TimeInterval = 91 * 86_400

    private struct FileState: Codable {
        var size: UInt64
        var modified: Date
        /// Byte offset just past the last complete line already parsed.
        var offset: UInt64
        var entries: [UsageEntry] = []

        // Codex only.
        /// Entries derived from cumulative `token_count` events, used only for
        /// older logs that have no per-response `token_usage_record` lines.
        var fallbackEntries: [UsageEntry] = []
        var hasUsageRecords = false
        var currentModel: String?
        var turnModels: [String: String] = [:]
        var lastCumulative: TokenCounts?
    }

    private struct Cache: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var files: [String: FileState] = [:]
    }

    private var cache: Cache?
    private let cacheURL: URL
    private let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain = ISO8601DateFormatter()

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
    }

    private static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CodeBarAI", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    // MARK: - Scanning

    func scan(claudeDirectories: [URL], codexDirectories: [URL], now: Date = Date()) -> UsageReport {
        var cache = loadCache()
        let cutoff = now.addingTimeInterval(-Self.retention)
        var changed = false
        var seenPaths = Set<String>()
        var sourcesFound = Set<UsageSource>()

        let roots: [(URL, UsageSource)] =
            claudeDirectories.map { ($0.appendingPathComponent("projects", isDirectory: true), .claude) }
            + codexDirectories.flatMap {
                [($0.appendingPathComponent("sessions", isDirectory: true), UsageSource.codex),
                 ($0.appendingPathComponent("archived_sessions", isDirectory: true), .codex)]
            }

        for (root, source) in roots {
            for file in Self.logFiles(in: root) {
                sourcesFound.insert(source)
                guard file.modified >= cutoff, seenPaths.insert(file.path).inserted else { continue }

                var state = cache.files[file.path]
                    ?? FileState(size: 0, modified: .distantPast, offset: 0)
                if state.size == file.size && state.modified == file.modified { continue }
                if file.size < state.offset {
                    // Rewritten rather than appended to: start over.
                    state = FileState(size: 0, modified: .distantPast, offset: 0)
                }
                parse(file: file, source: source, into: &state)
                state.size = file.size
                state.modified = file.modified
                state.entries.removeAll { $0.date < cutoff }
                state.fallbackEntries.removeAll { $0.date < cutoff }
                cache.files[file.path] = state
                changed = true
            }
        }

        // Forget files that were deleted or aged out.
        let stale = cache.files.keys.filter { !seenPaths.contains($0) }
        if !stale.isEmpty {
            stale.forEach { cache.files.removeValue(forKey: $0) }
            changed = true
        }

        self.cache = cache
        if changed { saveCache(cache) }

        var report = Self.aggregate(Self.uniqueEntries(in: cache), now: now)
        report.sourcesFound = sourcesFound
        return report
    }

    private struct LogFile {
        let path: String
        let size: UInt64
        let modified: Date
    }

    private static func logFiles(in root: URL) -> [LogFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [LogFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            files.append(LogFile(path: url.path, size: UInt64(size), modified: modified))
        }
        return files
    }

    // MARK: - Parsing

    private func parse(file: LogFile, source: UsageSource, into state: inout FileState) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped),
              UInt64(data.count) > state.offset
        else { return }

        let start = Int(state.offset)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var lineStart = start
            let end = buffer.count
            while lineStart < end {
                guard let newline = memchr(base + lineStart, 0x0A, end - lineStart) else {
                    // An unfinished last line is read on the next scan.
                    break
                }
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                let line = UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart)
                switch source {
                case .claude:
                    parseClaudeLine(line, path: file.path, offset: lineStart, into: &state)
                case .codex:
                    parseCodexLine(line, path: file.path, offset: lineStart, into: &state)
                }
                lineStart = lineEnd + 1
            }
            state.offset = UInt64(lineStart)
        }
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    private static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!),
                        count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private func parseClaudeLine(_ line: UnsafeRawBufferPointer, path: String, offset: Int, into state: inout FileState) {
        // Most lines are user messages and tool output. Skip them unparsed.
        guard line.count > 0,
              Self.contains(line, "\"usage\""),
              Self.contains(line, "\"assistant\""),
              let object = Self.object(line),
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              !model.hasPrefix("<"),
              let date = date(object["timestamp"])
        else { return }

        var tokens = TokenCounts(
            input: Self.int(usage["input_tokens"]),
            output: Self.int(usage["output_tokens"]),
            cacheRead: Self.int(usage["cache_read_input_tokens"])
        )
        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite = Self.int(creation["ephemeral_5m_input_tokens"])
            tokens.cacheWriteLong = Self.int(creation["ephemeral_1h_input_tokens"])
        } else {
            tokens.cacheWrite = Self.int(usage["cache_creation_input_tokens"])
        }
        guard tokens.total > 0 else { return }

        let key: String
        if let id = message["id"] as? String {
            key = "c:\(id):\(object["requestId"] as? String ?? "")"
        } else {
            key = "c:\(path):\(offset)"
        }
        state.entries.append(UsageEntry(
            key: key,
            date: date,
            source: .claude,
            model: model,
            tokens: tokens,
            isUSOnly: usage["inference_geo"] as? String == "us"
        ))
    }

    /// OpenAI counts cached and cache-write tokens inside `input_tokens`;
    /// split them out so the buckets do not overlap.
    private static func codexTokens(_ usage: [String: Any]) -> TokenCounts {
        let input = int(usage["input_tokens"])
        let cached = int(usage["cached_input_tokens"])
        let written = int(usage["cache_write_input_tokens"])
        return TokenCounts(
            input: max(0, input - cached - written),
            output: int(usage["output_tokens"]),
            cacheRead: cached,
            cacheWrite: written
        )
    }

    private func parseCodexLine(_ line: UnsafeRawBufferPointer, path: String, offset: Int, into state: inout FileState) {
        guard line.count > 0,
              Self.contains(line, "\"turn_context\"")
                || Self.contains(line, "\"token_usage_record\"")
                || Self.contains(line, "\"token_count\""),
              let object = Self.object(line),
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        switch type {
        case "turn_context":
            guard let model = payload["model"] as? String else { return }
            state.currentModel = model
            if let turn = payload["turn_id"] as? String { state.turnModels[turn] = model }

        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any],
                  let date = date(object["timestamp"])
            else { return }
            let tokens = Self.codexTokens(usage)
            guard tokens.total > 0 else { return }
            state.hasUsageRecords = true
            let model = (payload["turn_id"] as? String).flatMap { state.turnModels[$0] }
                ?? state.currentModel ?? "unknown"
            let key = (payload["response_id"] as? String).map { "x:\($0)" } ?? "x:\(path):\(offset)"
            state.entries.append(UsageEntry(key: key, date: date, source: .codex, model: model, tokens: tokens))

        case "event_msg" where payload["type"] as? String == "token_count":
            guard !state.hasUsageRecords,
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let date = date(object["timestamp"])
            else { return }
            let cumulative = Self.codexTokens(total)
            var delta = cumulative
            if let last = state.lastCumulative {
                delta = TokenCounts(
                    input: cumulative.input - last.input,
                    output: cumulative.output - last.output,
                    cacheRead: cumulative.cacheRead - last.cacheRead,
                    cacheWrite: cumulative.cacheWrite - last.cacheWrite
                )
                if delta.input < 0 || delta.output < 0 || delta.cacheRead < 0 || delta.cacheWrite < 0 {
                    // The counter restarted; fall back to the last response alone.
                    delta = (info["last_token_usage"] as? [String: Any]).map(Self.codexTokens) ?? TokenCounts()
                }
            }
            state.lastCumulative = cumulative
            guard delta.total > 0 else { return }
            state.fallbackEntries.append(UsageEntry(
                key: "x:\(path):\(offset)",
                date: date,
                source: .codex,
                model: state.currentModel ?? "unknown",
                tokens: delta
            ))

        default:
            return
        }
    }

    // MARK: - Aggregation

    /// Claude Code writes a response once per content block with the same
    /// usage, and resumed sessions repeat earlier messages. Keep one record per
    /// response, preferring the most complete output count.
    private static func uniqueEntries(in cache: Cache) -> [UsageEntry] {
        var byKey: [String: UsageEntry] = [:]
        for state in cache.files.values {
            let entries = state.hasUsageRecords ? state.entries : state.entries + state.fallbackEntries
            for entry in entries {
                if let existing = byKey[entry.key], existing.tokens.output >= entry.tokens.output { continue }
                byKey[entry.key] = entry
            }
        }
        return Array(byKey.values)
    }

    static func aggregate(_ entries: [UsageEntry], now: Date) -> UsageReport {
        let calendar = Calendar.current
        var report = UsageReport(generatedAt: now)
        let priced = entries.map { ($0, ModelPricing.cost(of: $0)) }

        for period in UsagePeriod.allCases {
            let periodStart = now.addingTimeInterval(-period.duration)
            var result = PeriodReport()
            var models: [String: ModelUsage] = [:]

            // Bars: hours for a day, days for a week or month, weeks for 90 days.
            let bucketStarts: [Date]
            let bucketIndex: (Date) -> Int?
            switch period {
            case .day:
                let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
                bucketStarts = (0..<24).map { hour.addingTimeInterval(TimeInterval($0 - 23) * 3_600) }
                let first = bucketStarts[0]
                bucketIndex = { date in
                    let index = Int(date.timeIntervalSince(first) / 3_600)
                    return (0..<24).contains(index) ? index : nil
                }
                result.bucketLength = .hour
            case .week, .month:
                let today = calendar.startOfDay(for: now)
                let count = period.days
                bucketStarts = (0..<count).compactMap {
                    calendar.date(byAdding: .day, value: $0 - (count - 1), to: today)
                }
                let first = bucketStarts.first ?? today
                bucketIndex = { date in
                    guard let index = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day
                    else { return nil }
                    return (0..<count).contains(index) ? index : nil
                }
                result.bucketLength = .day
            case .quarter:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
                bucketStarts = (0..<13).compactMap {
                    calendar.date(byAdding: .day, value: ($0 - 13) * 7, to: tomorrow)
                }
                let first = bucketStarts.first ?? now
                bucketIndex = { date in
                    guard let days = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day,
                          days >= 0 else { return nil }
                    let index = days / 7
                    return index < 13 ? index : nil
                }
                result.bucketLength = .weekOfYear
            }
            var buckets = bucketStarts.map { UsageBucket(start: $0) }

            for (entry, cost) in priced where entry.date >= periodStart && entry.date <= now {
                result.totals.add(entry, cost: cost)
                result.bySource[entry.source, default: UsageTotals()].add(entry, cost: cost)

                let modelKey = "\(entry.source.rawValue):\(entry.model)"
                var model = models[modelKey] ?? ModelUsage(model: entry.model, source: entry.source)
                model.totals.add(entry, cost: cost)
                if cost == nil { model.isPriced = false }
                models[modelKey] = model

                if let index = bucketIndex(entry.date) {
                    buckets[index].bySource[entry.source, default: UsageTotals()].add(entry, cost: cost)
                }
            }

            result.models = models.values.sorted {
                $0.totals.cost != $1.totals.cost
                    ? $0.totals.cost > $1.totals.cost
                    : $0.totals.tokens.total > $1.totals.tokens.total
            }
            result.buckets = buckets
            report.periods[period] = result
        }
        return report
    }

    // MARK: - Cache

    private func loadCache() -> Cache {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data),
              decoded.version == Cache.currentVersion
        else { return Cache() }
        return decoded
    }

    private func saveCache(_ cache: Cache) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            // The cache only saves time. Without it the next scan reads everything again.
        }
    }
}
