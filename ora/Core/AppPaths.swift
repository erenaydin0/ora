import Foundation

/// Uygulamanın diskteki tek yol otoritesi.
/// Yol asla sabit yazılmaz; her şey `applicationSupportDirectory` altından türetilir.
enum AppPaths {

    /// `~/Library/Application Support/ora/`
    static let base: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appending(path: "ora", directoryHint: .isDirectory)
    }()

    /// `{base}/recordings/`
    static let recordings = base.appending(path: "recordings", directoryHint: .isDirectory)

    /// `{base}/logs/`
    static let logs = base.appending(path: "logs", directoryHint: .isDirectory)

    /// `{base}/ora.sqlite`
    static let database = base.appending(path: "ora.sqlite", directoryHint: .notDirectory)

    /// `{base}/logs/ora.log`
    static let logFile = logs.appending(path: "ora.log", directoryHint: .notDirectory)

    /// `{base}/recordings/{meeting_id}.wav`
    static func recording(meetingID: Int64) -> URL {
        recordings.appending(path: "\(meetingID).wav", directoryHint: .notDirectory)
    }

    /// Uygulama açılışında bir kez çağrılır. Dizinler yoksa oluşturulur.
    /// Hata sessizce yutulmaz — çağıran tarafa fırlatılır.
    static func prepare() throws {
        for directory in [base, recordings, logs] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
    }
}
