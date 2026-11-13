// Jev: TypeSafe's System One model, the first choice for finding answers (Nemotron.swift has the
// rest). It's asked typed questions (Choice, Noul) about text and answers with probabilities.
// Same API and retry rules as the Chrome extension's scorer.js.

import Foundation

struct JevError: Error, LocalizedError {
    enum Code: String { case noKey, badKey, noFunds, busy, timeout, offline, tooBig, server, freePlan }
    let code: Code
    let message: String
    var errorDescription: String? { message }

    /// What the bar says, in plain English.
    var plain: String {
        switch code {
        case .noKey: return "No key yet. Add a Jev key or a Nebius key (for Nemotron) in settings to search by meaning."
        case .badKey: return "Jev didn't accept your key. Check it in settings."
        case .noFunds: return "Your Jev account is out of funds. Add funds at console.typesafe.ai, under Billing."
        case .busy: return "Jev is busy right now. Try again in a few seconds."
        case .timeout: return "Jev took too long to answer. Try again."
        case .offline: return "Couldn't reach Jev. Check your internet connection."
        case .tooBig: return "This is too long to search in one go."
        case .server: return "Jev returned an error. Try again."
        case .freePlan: return "Search by meaning is part of the AI plan."
        }
    }
}

/// One option of a Choice question: its id and what it means.
struct JevOption {
    let id: String
    let text: String?
}

struct JevAnswers {
    let raw: [String: Any]
    let tokens: Int
    let ms: Int

    func choice(_ question: String) -> (pick: String?, probabilities: [String: Double], confidence: Double) {
        let answer = raw[question] as? [String: Any] ?? [:]
        let probabilities = (answer["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return (answer["choice"] as? String, probabilities, (answer["confidence"] as? NSNumber)?.doubleValue ?? 0)
    }

    func noul(_ question: String) -> Double {
        ((raw[question] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue ?? 0
    }
}

final class Jev {
    static let shared = Jev()
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let maxOptions = 255
    static let maxStateChars = 120_000

    private let retries = 3
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Pareto-Mac"]
        return URLSession(configuration: config)
    }()

    /// Tokens used since launch, for the self-test's spend log.
    private let countLock = NSLock()
    private var tokenCount = 0
    var tokensUsed: Int { countLock.withLock { tokenCount } }

    static func choice(_ instructions: String, _ options: [JevOption]) -> [String: Any] {
        var criteria: [String: Any] = [:]
        for option in options { criteria[option.id] = option.text ?? NSNull() }
        return ["type": "choice", "instructions": instructions, "criteria": criteria]
    }

    static func noul(_ instructions: String, yes: String, no: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions, "criteria": ["true": yes, "false": no]]
    }

    func ask(state: String, questions: [String: [String: Any]]) async throws -> JevAnswers {
        guard let key = Settings.shared.jevKey else { throw JevError(code: .noKey, message: "No Jev key is saved.") }
        let body: [String: Any] = ["state": state, "model": Jev.model, "questions": questions]
        var request = URLRequest(url: Jev.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        for attempt in 0... {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                throw JevError(code: .timeout, message: "Jev didn't answer within 15 seconds.")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw JevError(code: .offline, message: "Couldn't reach Jev: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let tokens = ((json["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue ?? 0
                countLock.withLock { tokenCount += tokens }
                return JevAnswers(raw: json["answers"] as? [String: Any] ?? [:], tokens: tokens,
                                  ms: Int(Date().timeIntervalSince(started) * 1000))
            }
            let retryable = status == 408 || status == 429 || status >= 500
            if retryable && attempt < retries {
                let wait = min(0.5 * pow(2, Double(attempt)), 5) * (1 - 0.25 * Double.random(in: 0...1))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            // Out of funds: HTTP 402, or a refusal that says so.
            let aboutMoney = ["fund", "credit", "balance", "billing", "payment"].contains { detail.lowercased().contains($0) }
            if status == 402 || ((400..<500).contains(status) && status != 429 && aboutMoney) {
                throw JevError(code: .noFunds, message: "Jev returned HTTP \(status): \(detail)")
            }
            if status == 401 { throw JevError(code: .badKey, message: "Jev didn't accept the key.") }
            if status == 429 || status == 529 { throw JevError(code: .busy, message: "Jev was still busy after \(retries) retries.") }
            throw JevError(code: .server, message: "Jev returned HTTP \(status): \(detail)")
        }
        throw JevError(code: .server, message: "unreachable")
    }
}

// MARK: - Line search, the pattern from the prototype ticket

struct Line {
    let id: String
    let text: String
    var path: [String] = []
    var formatted: String { path.isEmpty ? "\(id)| \(text)" : "\(id)| [\(path.joined(separator: " > "))] \(text)" }
}

struct LineHit {
    let id: String
    let score: Double
}

struct LineSearch {
    let exists: Double
    let top: [LineHit]
    let ms: Int
    let calls: Int
    /// Which model found it: "Jev", or "Lightning" when Nemotron stood in.
    var engine = "Jev"
    /// Why Lightning stood in for Jev, in a few words, when it did.
    var because: String? = nil
}

extension Jev {
    /// Which line answers the question, and how sure Jev is that any line does. Too many
    /// lines for one call are split into windows asked at the same time (at most 8).
    func searchLines(_ lines: [Line], question: String) async throws -> LineSearch {
        if lines.isEmpty { return LineSearch(exists: 0, top: [], ms: 0, calls: 0) }
        let windows = try Jev.windows(for: lines)
        let started = Date()
        let replies = try await withThrowingTaskGroup(of: (Int, JevAnswers).self) { group in
            for (i, window) in windows.enumerated() {
                group.addTask {
                    let state = window.map(\.formatted).joined(separator: "\n")
                    let answers = try await self.ask(state: state, questions: [
                        "where": Jev.choice("Which line of the document contains the answer to: \"\(question)\"?",
                                            window.map { JevOption(id: $0.id, text: nil) }),
                        "exists": Jev.noul("Does any line of the document address or answer: \"\(question)\"?",
                                           yes: "At least one line of the document states or directly implies the answer",
                                           no: "No line of the document addresses this"),
                    ])
                    return (i, answers)
                }
            }
            var out: [(Int, JevAnswers)] = []
            for try await reply in group { out.append(reply) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var exists = 0.0
        var ranked: [LineHit] = []
        for (i, reply) in replies.enumerated() {
            let windowExists = reply.noul("exists")
            exists = max(exists, windowExists)
            let probabilities = reply.choice("where").probabilities
            for line in windows[i] {
                ranked.append(LineHit(id: line.id, score: windowExists * (probabilities[line.id] ?? 0)))
            }
        }
        ranked.sort { $0.score > $1.score }
        return LineSearch(exists: exists, top: Array(ranked.prefix(5)),
                          ms: Int(Date().timeIntervalSince(started) * 1000), calls: windows.count)
    }

    /// Which sentence of a matched passage answers the question. One sentence needs no call.
    func pickSentence(_ sentences: [String], question: String, heading: [String] = []) async throws -> Int {
        guard sentences.count > 1 else { return 0 }
        let ids = sentences.prefix(Jev.maxOptions).indices.map { "s\($0 + 1)" }
        let head = heading.isEmpty ? "" : "[\(heading.joined(separator: " > "))]\n"
        let state = head + zip(ids, sentences).map { "\($0)| \($1)" }.joined(separator: "\n")
        let answers = try await ask(state: state, questions: [
            "which": Jev.choice("Which sentence contains the answer to: \"\(question)\"?", ids.map { JevOption(id: $0, text: nil) }),
        ])
        let pick = answers.choice("which").pick ?? "s1"
        return max(0, ids.firstIndex(of: pick) ?? 0)
    }

    static func windows(for lines: [Line]) throws -> [[Line]] {
        let chars = lines.reduce(0) { $0 + $1.formatted.count + 1 }
        var n = max(1, Int(ceil(Double(lines.count) / Double(maxOptions))), Int(ceil(Double(chars) / Double(maxStateChars))))
        while true {
            if n > 8 { throw JevError(code: .tooBig, message: "Needs more than 8 calls to Jev.") }
            let size = Int(ceil(Double(lines.count) / Double(n)))
            let windows = stride(from: 0, to: lines.count, by: size).map { Array(lines[$0..<min($0 + size, lines.count)]) }
            let fits = windows.allSatisfy { w in
                w.count <= maxOptions && w.reduce(0) { $0 + $1.formatted.count + 1 } <= maxStateChars
            }
            if fits { return windows }
            n += 1
        }
    }
}
