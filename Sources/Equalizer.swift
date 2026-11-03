import Foundation

// MARK: - Profile model

struct EQFilter: Codable, Hashable {
    enum Kind: String, Codable { case peak, lowShelf, highShelf }
    let kind: Kind
    let frequency: Double   // Hz
    let gainDb: Double
    let q: Double
}

/// A parametric EQ, e.g. one of AutoEq's headphone corrections.
struct EQProfile: Codable, Hashable {
    let name: String        // e.g. "Apple AirPods Max"
    let source: String      // e.g. "oratory1990"
    let preampDb: Double
    let filters: [EQFilter]

    var displayName: String { "\(name) · \(source)" }

    /// Parses AutoEq's "ParametricEQ.txt" format:
    ///   Preamp: -4.7 dB
    ///   Filter 1: ON LSC Fc 105 Hz Gain -3.0 dB Q 0.70
    static func parse(_ text: String, name: String, source: String) -> EQProfile? {
        var preamp = 0.0
        var filters: [EQFilter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ").map(String.init)
            if parts.first == "Preamp:", parts.count >= 2, let v = Double(parts[1]) {
                preamp = v
                continue
            }
            guard parts.first == "Filter", parts.contains("ON") else { continue }
            func number(after key: String) -> Double? {
                guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
                return Double(parts[i + 1])
            }
            let kind: EQFilter.Kind
            if parts.contains("PK") { kind = .peak }
            else if parts.contains("LSC") || parts.contains("LS") { kind = .lowShelf }
            else if parts.contains("HSC") || parts.contains("HS") { kind = .highShelf }
            else { continue }
            guard let fc = number(after: "Fc"), let gain = number(after: "Gain") else { continue }
            let q = number(after: "Q") ?? 0.707
            filters.append(EQFilter(kind: kind, frequency: fc, gainDb: gain, q: q))
        }
        guard !filters.isEmpty else { return nil }
        return EQProfile(name: name, source: source, preampDb: preamp, filters: filters)
    }

    /// Combined frequency response in dB (including preamp) at the given frequencies.
    func response(at frequencies: [Double], sampleRate: Double = 48_000) -> [Double] {
        let biquads = filters.map { Biquad(filter: $0, sampleRate: sampleRate) }
        return frequencies.map { f in
            preampDb + biquads.reduce(0) { $0 + $1.magnitudeDb(at: f, sampleRate: sampleRate) }
        }
    }
}

// MARK: - Biquad design (RBJ Audio EQ Cookbook)

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    init(filter: EQFilter, sampleRate: Double) {
        let f = min(max(filter.frequency, 10), sampleRate * 0.49)
        let A = pow(10, filter.gainDb / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * max(filter.q, 0.01))
        let sqrtA2alpha = 2 * sqrt(A) * alpha

        var a0 = 1.0
        switch filter.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cosw + sqrtA2alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - sqrtA2alpha)
            a0 = (A + 1) + (A - 1) * cosw + sqrtA2alpha
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - sqrtA2alpha
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cosw + sqrtA2alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - sqrtA2alpha)
            a0 = (A + 1) - (A - 1) * cosw + sqrtA2alpha
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - sqrtA2alpha
        }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    }

    func magnitudeDb(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let mag2 = (numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-30)
        return 10 * log10(max(mag2, 1e-30))
    }
}

// MARK: - Real-time processor

/// Filter coefficients plus per-channel state, allocated up front so the
/// audio thread never allocates. Built once per tap; a profile change
/// rebuilds the tap rather than editing this live.
final class EQRuntime {
    static let maxChannels = 8

    let filterCount: Int
    let preampGain: Float
    private let coeffs: UnsafeMutablePointer<Double>   // 5 per filter
    private let state: UnsafeMutablePointer<Double>    // 2 per filter per channel

    init(profile: EQProfile, sampleRate: Double) {
        filterCount = profile.filters.count
        preampGain = Float(pow(10, profile.preampDb / 20))
        coeffs = .allocate(capacity: max(filterCount, 1) * 5)
        state = .allocate(capacity: max(filterCount, 1) * 2 * EQRuntime.maxChannels)
        state.initialize(repeating: 0, count: max(filterCount, 1) * 2 * EQRuntime.maxChannels)
        for (i, f) in profile.filters.enumerated() {
            let b = Biquad(filter: f, sampleRate: sampleRate)
            coeffs[i * 5 + 0] = b.b0
            coeffs[i * 5 + 1] = b.b1
            coeffs[i * 5 + 2] = b.b2
            coeffs[i * 5 + 3] = b.a1
            coeffs[i * 5 + 4] = b.a2
        }
    }

    /// Filters `frames` samples in place for one channel (transposed direct form II).
    func process(channel: Int, samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard channel < EQRuntime.maxChannels else { return }
        for i in 0..<filterCount {
            let b0 = coeffs[i * 5], b1 = coeffs[i * 5 + 1], b2 = coeffs[i * 5 + 2]
            let a1 = coeffs[i * 5 + 3], a2 = coeffs[i * 5 + 4]
            let s = state + (channel * filterCount + i) * 2
            var z1 = s[0], z2 = s[1]
            for n in 0..<frames {
                let x = Double(samples[n])
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[n] = Float(y)
            }
            s[0] = z1
            s[1] = z2
        }
    }

    deinit {
        coeffs.deallocate()
        state.deallocate()
    }
}

// MARK: - AutoEq catalog

struct EQCatalogEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String     // "Apple AirPods Max"
    let source: String   // "oratory1990" or "crinacle on GRAS 43AG-7"
    let path: String     // "oratory1990/over-ear/Apple%20AirPods%20Max" (URL-encoded)
}

/// Downloads and searches AutoEq's index of headphone corrections
/// (github.com/jaakkopasanen/AutoEq). The index is cached for a week.
@MainActor
final class EQCatalog: ObservableObject {
    static let shared = EQCatalog()

    enum Status: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var entries: [EQCatalogEntry] = []
    @Published private(set) var status: Status = .idle

    private let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private let cacheURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VolumeMixer", isDirectory: true)
            .appendingPathComponent("autoeq-index.md")
    }()

    func loadIfNeeded() async {
        guard status == .idle || { if case .failed = status { return true } else { return false } }() else { return }
        status = .loading

        let fm = FileManager.default
        let cached = try? String(contentsOf: cacheURL, encoding: .utf8)
        let age = (try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity

        if let cached, age < 7 * 86_400 {
            entries = Self.parseIndex(cached)
            status = entries.isEmpty ? .failed("The cached headphone list was empty.") : .ready
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "INDEX.md")!)
            let text = String(decoding: data, as: UTF8.self)
            let parsed = Self.parseIndex(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
            entries = parsed
            status = .ready
        } catch {
            if let cached {
                entries = Self.parseIndex(cached)   // stale but usable
                status = .ready
            } else {
                status = .failed("Couldn't download the headphone list: \(error.localizedDescription)")
            }
        }
    }

    func search(_ query: String, limit: Int = 80) -> [EQCatalogEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return Array(entries.lazy.filter { e in
            let hay = (e.name + " " + e.source).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.prefix(limit))
    }

    func fetchProfile(_ entry: EQCatalogEntry) async throws -> EQProfile {
        let folder = entry.path.split(separator: "/").last.map(String.init) ?? ""
        guard let url = URL(string: base + entry.path + "/" + folder + "%20ParametricEQ.txt") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.fileDoesNotExist)
        }
        guard let profile = EQProfile.parse(String(decoding: data, as: UTF8.self),
                                            name: entry.name, source: entry.source) else {
            throw URLError(.cannotParseResponse)
        }
        return profile
    }

    /// Lines look like:
    /// - [Apple AirPods Max](./oratory1990/over-ear/Apple%20AirPods%20Max) by oratory1990
    /// Names and paths can contain parentheses, so split on "](" and the last ") by ".
    nonisolated static func parseIndex(_ text: String) -> [EQCatalogEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("- ["),
                  let mid = line.range(of: "]("),
                  let by = line.range(of: ") by ", options: .backwards),
                  mid.upperBound <= by.lowerBound else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<mid.lowerBound])
            var path = String(line[mid.upperBound..<by.lowerBound])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let source = String(line[by.upperBound...])
            return EQCatalogEntry(name: name, source: source, path: path)
        }
    }
}
