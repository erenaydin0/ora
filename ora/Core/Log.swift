import Foundation
import OSLog

/// Uygulamanın günlük kategorileri. Yeni bir modül eklenince buraya bir vaka eklenir.
enum LogCategory: String {
    case app          = "app"
    case capture      = "capture"
    case transcribe   = "transcribe"
    case intelligence = "intelligence"
    case calendar     = "calendar"
    case store        = "store"
    case pipeline     = "pipeline"
    case ui           = "ui"
}

enum LogLevel: String {
    case debug   = "AYIKLA"
    case info    = "BİLGİ"
    case warning = "UYARI"
    case error   = "HATA"
}

/// OSLog + `{base}/logs/ora.log` dosya köprüsü.
///
/// Konsola OSLog üzerinden, diske düz metin olarak yazar. Dosya yazımı arka plan
/// kuyruğunda ve en iyi çaba ile yapılır — günlük yazamamak uygulamayı durdurmaz,
/// ama sessizce de geçilmez: OSLog'a bir kez hata düşer.
enum Log {

    static func debug(_ category: LogCategory, _ message: String) {
        emit(.debug, category, message)
    }

    static func info(_ category: LogCategory, _ message: String) {
        emit(.info, category, message)
    }

    static func warning(_ category: LogCategory, _ message: String) {
        emit(.warning, category, message)
    }

    static func error(_ category: LogCategory, _ message: String, _ error: Error? = nil) {
        if let error {
            emit(.error, category, "\(message) — \(describe(error))")
        } else {
            emit(.error, category, message)
        }
    }

    /// `localizedDescription` köprülenmiş Swift hatalarında hiçbir şey söylemez
    /// ("Foundation._GenericObjCError hatası 0"). Hatanın kendi tanımı da
    /// yazılır — log teşhis içindir, kullanıcı metni değil.
    static func describe(_ error: Error) -> String {
        let localized = error.localizedDescription
        let raw = String(describing: error)
        return localized.contains(raw) ? localized : "\(localized) [\(raw)]"
    }

    // MARK: - Uygulama

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.orameetings.ora"

    private static let loggers: [LogCategory: Logger] = {
        var map: [LogCategory: Logger] = [:]
        for category in [LogCategory.app, .capture, .transcribe, .intelligence,
                         .calendar, .store, .pipeline, .ui] {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    private static func emit(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)")
        }
        FileLogSink.shared.write(level: level, category: category, message: message)
    }
}

/// `{base}/logs/ora.log` dosyasına satır ekler. Seri kuyruk, açık tutulan dosya tanıtıcısı.
private final class FileLogSink: @unchecked Sendable {

    static let shared = FileLogSink()

    private let queue = DispatchQueue(label: "ora.log.file", qos: .utility)
    private var handle: FileHandle?
    private var openFailed = false

    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func write(level: LogLevel, category: LogCategory, message: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            guard let handle = self.openHandle() else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                self.reportOpenFailure(error)
            }
        }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        if openFailed { return nil }
        do {
            try AppPaths.prepare()
            let path = AppPaths.logFile.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: AppPaths.logFile)
            self.handle = handle
            return handle
        } catch {
            reportOpenFailure(error)
            return nil
        }
    }

    private func reportOpenFailure(_ error: Error) {
        guard !openFailed else { return }
        openFailed = true
        handle = nil
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.orameetings.ora", category: "app")
            .error("Günlük dosyası yazılamıyor: \(error.localizedDescription, privacy: .public)")
    }
}
