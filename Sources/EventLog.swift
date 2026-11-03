import AppKit
import Foundation

struct LogEvent: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case launched
        case quit
        case tapStarted
        case tapStopped
        case dropout
        case dropoutIgnored   // happened within 2 s of a tap/buffer change; not counted
        case bufferUp
        case bufferDown
        case outputChanged
        case error

        var label: String {
            switch self {
            case .launched: "App launched"
            case .quit: "App quit"
            case .tapStarted: "Started adjusting"
            case .tapStopped: "Stopped adjusting"
            case .dropout: "Dropout"
            case .dropoutIgnored: "Dropout (ignored, during a change)"
            case .bufferUp: "Buffer increased"
            case .bufferDown: "Buffer decreased"
            case .outputChanged: "Output device changed"
            case .error: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .launched: "power"
            case .quit: "power.dotted"
            case .tapStarted: "slider.horizontal.3"
            case .tapStopped: "slider.horizontal.below.rectangle"
            case .dropout: "exclamationmark.triangle.fill"
            case .dropoutIgnored: "exclamationmark.triangle"
            case .bufferUp: "arrow.up.circle"
            case .bufferDown: "arrow.down.circle"
            case .outputChanged: "hifispeaker"
            case .error: "xmark.octagon"
            }
        }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let detail: String?
    /// Added delay in effect right after this event (0 = no apps being adjusted).
    let delayMs: Double
}

/// Local, append-only log of audio events.
/// Stored at ~/Library/Application Support/VolumeMixer/events.jsonl and never sent anywhere.
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()

    @Published private(set) var events: [LogEvent] = []

    private let maxEvents = 5000
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VolumeMixer", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func add(_ kind: LogEvent.Kind, detail: String? = nil, delayMs: Double) {
        let event = LogEvent(date: Date(), kind: kind, detail: detail, delayMs: delayMs)
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
            rewriteFile()
        } else {
            appendToFile(event)
        }
    }

    func clear() {
        events.removeAll()
        rewriteFile()
    }

    func revealInFinder() {
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: File I/O

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let loaded = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(LogEvent.self, from: Data(line.utf8))
        }
        events = Array(loaded.suffix(maxEvents))
        if loaded.count > maxEvents { rewriteFile() }
    }

    private func appendToFile(_ event: LogEvent) {
        ensureDirectory()
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }

    private func rewriteFile() {
        ensureDirectory()
        var data = Data()
        for event in events {
            if let line = try? encoder.encode(event) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
