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

    /// Sandbox'tan çıkıldığında bir kereye mahsus veri göçü.
    ///
    /// Sandbox'lı uygulamanın "Application Support" dizini konteynerin
    /// içindedir; sandbox kalkınca `FileManager` gerçek dizini döndürür ve
    /// eski veritabanı, ses kayıtları ve sözlük **görünmez olur**. Göç
    /// yapılmazsa kullanıcı bütün toplantılarını kaybettiğini sanır.
    ///
    /// Kopyalanır, taşınmaz: göç yarıda kalırsa eski veri yerinde durur.
    /// Hedefte `ora.sqlite` varsa hiçbir şey yapılmaz — göç bir kez olur.
    static func migrateFromSandboxContainer(bundleID: String) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: database.path(percentEncoded: false)) else { return }

        let container = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(bundleID)/Data/Library/Application Support/ora",
                       directoryHint: .isDirectory)
        let oldDatabase = container.appending(path: "ora.sqlite", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: oldDatabase.path(percentEncoded: false)) else { return }

        do {
            try prepare()
            // Günlük dizini kopyalanmaz: yeni kurulumun kendi günlüğü var ve
            // eskisi konteynerde okunabilir durumda kalıyor.
            let copied = try mergeCopy(from: container, to: base, skipping: ["logs"])
            Log.info(.app, "Sandbox konteynerinden \(copied) dosya taşındı — eski veri "
                     + "yerinde bırakıldı: \(container.path(percentEncoded: false))")
        } catch {
            Log.error(.app, "Sandbox konteyner göçü başarısız", error)
        }
    }

    /// Dizini **birleştirerek** kopyalar: hedefte var olan dosyaya dokunmaz,
    /// olmayanı kopyalar, alt dizinlere iner.
    ///
    /// Düz `copyItem` yetmiyor: hedefte boş bir `recordings/` dizini varsa
    /// (uygulama açılışta oluşturuyor) `copyItem` onu atlar ve ses kayıtları
    /// sessizce taşınmaz.
    @discardableResult
    private static func mergeCopy(from source: URL, to destination: URL,
                                  skipping: Set<String> = []) throws -> Int {
        let fileManager = FileManager.default
        var copied = 0
        for entry in try fileManager.contentsOfDirectory(at: source,
                                                         includingPropertiesForKeys: [.isDirectoryKey]) {
            guard !skipping.contains(entry.lastPathComponent) else { continue }
            let target = destination.appending(path: entry.lastPathComponent)
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                copied += try mergeCopy(from: entry, to: target)
            } else if !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                try fileManager.copyItem(at: entry, to: target)
                copied += 1
            }
        }
        return copied
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
