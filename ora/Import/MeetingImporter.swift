import Foundation

/// Dışarıdan gelen bir dosyayı ya da yapıştırılmış bir metni toplantıya
/// çevirir ve hattın nereden devam edeceğini söyler.
///
/// **Hattı kendisi koşturmaz.** Ses içe aktarımı tam geçişten, transkript içe
/// aktarımı özetlemeden başlar; hangisinin koşacağına karar veren yer
/// `RecordingController`'dır — hat orada kuruluyor ve "aynı anda tek hat"
/// kuralı orada tutuluyor. Bu tip yalnızca **içe aktarma politikasının**
/// sahibi: başlık nereden gelir, tarih nereden gelir, dosya nereye yazılır,
/// çözümlenemeyen girdide ne olur.
///
/// İki geri çağrı arayüz içindir:
/// - `onCreated` satır açıldığı anda tetiklenir; arayüz toplantıyı seçer ve
///   kullanıcı ne olduğunu **hemen** görür. Transkriptte satır yazıldıktan
///   sonra çağrılır, yoksa arayüz boş bir toplantı okur.
/// - `onStage` ses çevrimi sürerken ilerleme gösterir. Hat henüz başlamadığı
///   için aşamayı bu adım için hattan alamayız (`PipelineStage.importing`).
final class MeetingImporter {

    /// İçe aktarılabilecek üç şey. Transkriptin iki yolu olması kullanıcının
    /// isteği: dökümü dosya olarak da veriyor, panodan da yapıştırıyor.
    enum Source {
        case audio(URL)
        case transcriptFile(URL)
        case transcriptText(String)
    }

    /// Hattın nereden devam edeceği.
    enum Outcome {
        /// Ses diskte; hat **tam geçişten** başlar (transkript + özet).
        case audio(meetingID: Int64, url: URL)
        /// Transkript yazıldı; hat **özetlemeden** başlar.
        case transcript(meetingID: Int64, segments: [Segment])

        var meetingID: Int64 {
            switch self {
            case .audio(let id, _), .transcript(let id, _): id
            }
        }
    }

    /// Transkript olarak okunacak uzantılar. Dosya seçici ve sürükle-bırak
    /// aynı listeyi kullanır — biri kabul edip öteki reddetmesin.
    static let transcriptExtensions: Set<String> = [
        "txt", "md", "markdown", "vtt", "srt", "text", "log",
    ]

    var onCreated: ((Int64) -> Void)?
    var onStage: ((Int64, PipelineStage) -> Void)?

    private let store: MeetingStore
    private let settings: OraSettings

    init(store: MeetingStore, settings: OraSettings) {
        self.store = store
        self.settings = settings
    }

    func perform(_ source: Source) async throws -> Outcome {
        switch source {
        case .audio(let url):
            return try await importAudio(url)
        case .transcriptFile(let url):
            let text = try Self.readText(url)
            // Belgenin kendi başlığı dosya adından iyidir.
            return try await importTranscript(
                text, title: TranscriptParser.title(in: text)
                    ?? url.deletingPathExtension().lastPathComponent,
                date: Self.fileDate(url))
        case .transcriptText(let text):
            return try await importTranscript(text, title: TranscriptParser.title(in: text),
                                              date: Date())
        }
    }

    // MARK: - Ses

    private func importAudio(_ url: URL) async throws -> Outcome {
        let date = Self.fileDate(url)
        let meetingID = try await store.createImportedMeeting(
            title: url.deletingPathExtension().lastPathComponent, date: date)
        onCreated?(meetingID)
        onStage?(meetingID, .importing(0))

        do {
            let target = AppPaths.recording(meetingID: meetingID)
            let duration = try await AudioImport.convert(url, to: target) { [weak self] value in
                Task { @MainActor in self?.onStage?(meetingID, .importing(value)) }
            }
            try await store.markProcessing(meetingID, audioPath: target, duration: duration)
            return .audio(meetingID: meetingID, url: target)
        } catch {
            // Yarım toplantı satırı bırakılmaz — kayıt başlatılamadığında da
            // aynısı yapılıyor.
            onStage?(meetingID, .idle)
            try? await store.delete(meetingID)
            Log.error(.store, "Ses içe aktarılamadı: \(url.lastPathComponent)", error)
            throw error
        }
    }

    // MARK: - Transkript

    private func importTranscript(_ text: String, title: String?, date: Date) async throws
        -> Outcome {

        let segments = TranscriptParser.parse(text, userName: settings.userDisplayName)
        guard !segments.isEmpty else {
            throw OraError.importFailed(
                reason: "Metinde konuşma satırı bulunamadı. Düz metin, Markdown, "
                    + ".vtt ve .srt dökümleri okunabilir.")
        }
        let meetingID = try await store.createImportedMeeting(
            title: title ?? "", date: date, duration: segments.last?.end ?? 0)
        try await store.replaceTranscript(meetingID, segments: segments)
        // Satır yazıldıktan **sonra**: arayüz seçtiği anda veritabanından
        // okuyor, boş bir toplantı görmemeli.
        onCreated?(meetingID)
        Log.info(.store, "Transkript içe aktarıldı — toplantı \(meetingID), "
                 + "\(segments.count) satır, "
                 + "\(Set(segments.map(\.speaker)).count) konuşmacı")
        return .transcript(meetingID: meetingID, segments: segments)
    }

    // MARK: - Dosya

    /// Metin dosyasını okur. Kodlama tahmini şart: Teams `.vtt` dosyasını
    /// UTF-8 verir ama Windows'tan gelen bir döküm Latin-5 olabilir ve
    /// `String(contentsOf:)` orada sessizce başarısız olur.
    static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw OraError.importFailed(reason: "Dosya okunamadı: \(url.lastPathComponent)")
        }
        let encodings: [String.Encoding] = [.utf8, .utf16, .windowsCP1254, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty { return text }
        }
        throw OraError.importFailed(
            reason: "Dosyanın metin kodlaması çözülemedi: \(url.lastPathComponent)")
    }

    /// İçe aktarılan kayıt **kendi gününe** düşsün: dün akşamki toplantı
    /// bugünün listesine değil dünün grubuna girer. Dosya tarihi okunamıyorsa
    /// ya da gelecekteyse "şimdi" kullanılır.
    static func fileDate(_ url: URL) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        let candidates = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }
        let now = Date()
        return candidates.filter { $0 < now }.min() ?? now
    }
}
