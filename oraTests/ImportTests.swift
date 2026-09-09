import Foundation
import AVFoundation
import Testing
@testable import ora

/// Çevrim ana iş parçacığının dışında koştuğu için ilerleme kilitle toplanır.
private nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// İçe aktarmanın ölçülen davranışı.
///
/// Ayrıştırıcının işi tahmin etmek; bu testler **neyin tahmin edilmeyeceğini**
/// de sabitliyor: tek geçen "Not:" öneki konuşmacı sayılmaz, iki satır aynı
/// ana denk gelmez, uzun paragraf tek segment kalmaz.
@Suite("İçe aktarma")
struct ImportTests {

    // MARK: - Altyazı biçimleri

    /// Teams dökümü: WebVTT + `<v Ad>` etiketi.
    @Test
    func vttKonusmaciVeZamaniOkur() {
        let vtt = """
        WEBVTT

        1
        00:00:02.100 --> 00:00:05.000
        <v Ayşe Yılmaz>Bordro çalışması ne durumda?</v>

        2
        00:00:05.400 --> 00:00:09.250 align:start position:0%
        <v Mehmet Kaya>Matrahlar hazır, işsizlik kesintisi kaldı.</v>
        """
        let segments = TranscriptParser.parse(vtt)

        #expect(segments.count == 2)
        #expect(segments[0].speaker == "Ayşe Yılmaz")
        #expect(segments[0].text == "Bordro çalışması ne durumda?")
        #expect(abs(segments[0].start - 2.1) < 0.001)
        #expect(abs(segments[1].end - 9.25) < 0.001, "hizalama ayarları bitiş damgasını bozmadı")
        #expect(segments[1].speaker == "Mehmet Kaya")
        #expect(segments.allSatisfy { $0.channel == .system },
                "kullanıcı adı verilmediyse herkes karşı taraftır")
    }

    /// SRT: virgüllü ondalık, sıra numarası ve `Ad:` öneki.
    @Test
    func srtSiraNumarasiniMetneKaristirmaz() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Ayşe: Merhaba.

        2
        00:00:03,500 --> 00:00:06,000
        Mehmet: Merhaba, başlayalım.
        """
        let segments = TranscriptParser.parse(srt)

        #expect(segments.count == 2)
        #expect(segments[0].text == "Merhaba.", "sıra numarası metne girmedi")
        #expect(segments[0].speaker == "Ayşe")
        #expect(abs(segments[1].start - 3.5) < 0.001)
    }

    /// Numara **gerçekten** metinse atılmaz.
    @Test
    func sayidanIbaretRepliKaybolmaz() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        2026

        00:00:03.000 --> 00:00:05.000
        Bütçe yılı bu.
        """
        let segments = TranscriptParser.parse(vtt)
        #expect(segments.count == 2)
        #expect(segments[0].text == "2026")
    }

    // MARK: - Düz metin

    @Test
    func duzMetindeTekrarEdenOnekKonusmacidir() {
        let text = """
        Ayşe: Bordro çalışması ne durumda?
        Mehmet: Matrahlar hazır.
        Ayşe: Peki ne zaman biter?
        Mehmet: Cuma günü.
        """
        let segments = TranscriptParser.parse(text)

        #expect(segments.count == 4)
        #expect(segments.map(\.speaker) == ["Ayşe", "Mehmet", "Ayşe", "Mehmet"])
        #expect(segments[0].text == "Bordro çalışması ne durumda?")
    }

    /// Tek geçen önek konuşmacı sayılmaz ama **metinde kalır**: atfedilmemiş
    /// bir satır, uydurulmuş bir kişiden iyidir.
    @Test
    func tekGecenAdMetinIcindeKalir() {
        let segments = TranscriptParser.parse("""
            Ayşe: Bordro ne durumda?
            Mehmet: Tamam, bekliyorum.
            Ayşe: Teşekkürler.
            """)

        #expect(segments.count == 3)
        #expect(segments[1].text == "Mehmet: Tamam, bekliyorum.",
                "ad metnin içinde duruyor, kesilmedi")
    }

    /// Tek geçen bir önek konuşmacı **değildir**; yoksa "Not: …" satırının
    /// metni yarıya iner.
    @Test
    func tekGecenOnekKonusmaciSayilmaz() {
        let text = """
        Ayşe: Bordro çalışması ne durumda?
        Not: bu satır bir açıklamadır.
        Ayşe: Peki ne zaman biter?
        """
        let segments = TranscriptParser.parse(text)

        #expect(segments.count == 3)
        #expect(segments[1].text == "Not: bu satır bir açıklamadır.",
                "metin bölünmedi")
        #expect(segments[1].speaker == Channel.system.speaker)
    }

    @Test
    func zamanDamgasiVeMarkdownIsaretleriOkunur() {
        let text = """
        - [00:01:02] Ayşe: İlk madde.
        - [00:02:30] Ayşe: İkinci madde.
        """
        let segments = TranscriptParser.parse(text)

        #expect(segments.count == 2)
        #expect(abs(segments[0].start - 62) < 0.001)
        #expect(abs(segments[1].start - 150) < 0.001)
        #expect(segments[0].text == "İlk madde.")
    }

    /// Kullanıcının kendi adı mikrofon kanalına düşer — özet isteminde "Ben"in
    /// kim olduğu buradan çıkıyor.
    @Test
    func kullanicininAdiMikrofonKanalinaDuser() {
        let text = """
        Eren: Ben hazırlayacağım.
        Mehmet: Tamam, bekliyorum.
        """
        let segments = TranscriptParser.parse(text, userName: "eren")

        #expect(segments[0].channel == .mic)
        #expect(segments[0].speaker == "Eren", "etiket kaynaktaki adı korur")
        #expect(segments[1].channel == .system)
    }

    /// Kanal etiketi yoksa "Katılımcı" yazılır — konuşmacı uydurulmaz.
    @Test
    func konusmacisizMetinKatilimciOlur() {
        let segments = TranscriptParser.parse("Toplantı bordro üzerine yapıldı.")
        #expect(segments.count == 1)
        #expect(segments[0].speaker == "Katılımcı")
        #expect(segments[0].channel == .system)
    }

    /// Markdown dökümü: `**Ad**: metin`. Vurgu işareti adın parçası değil —
    /// kesilmezse "Ayşe Yılmaz**" diye bir kişi özetleme istemine kadar gider.
    @Test
    func markdownVurgusuAddanKesilir() {
        let segments = TranscriptParser.parse("""
            **Ayşe Yılmaz**: Bordro ne durumda?
            **Mehmet Kaya**: Bu hafta bitiyor.
            **Ayşe Yılmaz**: Teşekkürler.
            """)

        #expect(segments.map(\.speaker) == ["Ayşe Yılmaz", "Mehmet Kaya", "Ayşe Yılmaz"])
    }

    /// Belgenin başındaki künye konuşma değildir: transkripte girerse hem
    /// sahte replikler olur hem de katılımcı adları özetleme istemine veri
    /// diye girer.
    @Test
    func belgeKunyesiTranskriptDegildir() {
        let text = """
            # Agentic payroll product
            **Date**: Wednesday, July 29, 2026 at 11:00 AM
            **Duration**: 1:18:29
            **People**: Çağrı Kilit, Osman Baykal
            **Çağrı Kilit**: Başlayalım.
            **Osman Baykal**: Hazırım.
            """
        let segments = TranscriptParser.parse(text)

        #expect(segments.count == 2, "künyeden replik üretilmedi")
        #expect(segments.map(\.speaker) == ["Çağrı Kilit", "Osman Baykal"])
        #expect(TranscriptParser.title(in: text) == "Agentic payroll product",
                "başlık belgenin kendisinden geliyor")
    }

    /// Konuşmanın **içindeki** iki nokta korunur; künye yalnızca belgenin
    /// başındadır.
    @Test
    func konusmaIcindekiKunyeKelimesiSilinmez() {
        let segments = TranscriptParser.parse("""
            **Ayşe**: Başlayalım.
            **Mehmet**: Tarih: 3 Eylül olarak konuşmuştuk.
            **Ayşe**: Doğru.
            """)
        #expect(segments.count == 3)
        #expect(segments[1].text == "Tarih: 3 Eylül olarak konuşmuştuk.")
    }

    // MARK: - Depolamanın dayattıkları

    /// `MeetingStore` satırı `(meeting_id, start_time, channel)` ile
    /// güncelliyor: iki satır aynı ana denk gelirse düzeltme yanlış satırı yazar.
    @Test
    func baslangicZamanlariKesinArtar() {
        let text = (1...30).map { "Ayşe: \($0). satır." }.joined(separator: "\n")
        let segments = TranscriptParser.parse(text)

        #expect(segments.count == 30)
        let starts = segments.map(\.start)
        #expect(Set(starts).count == starts.count, "hiçbir başlangıç tekrarlamıyor")
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 }, "sıra artıyor")
        #expect(segments.allSatisfy { $0.end > $0.start })
    }

    /// Aynı damgayı taşıyan iki replik (dışa aktarımlarda oluyor) da ayrışmalı.
    @Test
    func ayniDamgaliRepliklerCakismaz() {
        let vtt = """
        WEBVTT

        00:00:10.000 --> 00:00:12.000
        Ayşe: Bir.

        00:00:10.000 --> 00:00:12.000
        Mehmet: İki.
        """
        let segments = TranscriptParser.parse(vtt)
        #expect(segments.count == 2)
        #expect(segments[0].start < segments[1].start)
    }

    /// Tek parça yapıştırılmış uzun metin bölünmezse `TranscriptChunker`
    /// pencereyi taşırır ve o parça sessizce düşer.
    @Test
    func uzunParagrafCumleSinirindanBolunur() {
        let sentence = "Bordro matrahları bu ay yeniden hesaplandı ve tablo güncellendi. "
        let segments = TranscriptParser.parse(String(repeating: sentence, count: 40))

        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.text.count <= TranscriptParser.lineLimit })
        // Hiçbir şey atılmadı: kelime sayısı korunuyor.
        let words = segments.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.count
        #expect(words == sentence.split(whereSeparator: \.isWhitespace).count * 40)
    }

    /// Noktalaması hiç olmayan ham metin de bölünür — kelimeden.
    @Test
    func noktalamasizUzunMetinDeBolunur() {
        let segments = TranscriptParser.parse(String(repeating: "kelime ", count: 400))
        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.text.count <= TranscriptParser.lineLimit })
    }

    @Test
    func bosMetinSegmentUretmez() {
        #expect(TranscriptParser.parse("   \n\n  ").isEmpty)
    }

    // MARK: - Toplantıya çevirme

    @Test
    func transkriptIceAktarimiToplantiYazar() async throws {
        let database = try OraDatabase(path: ":memory:")
        let store = MeetingStore(database: database)
        let importer = MeetingImporter(store: store, settings: isolatedSettings())
        var created: Int64?
        importer.onCreated = { created = $0 }

        let outcome = try await importer.perform(.transcriptText("""
            Ayşe: Bordro çalışması bitti mi?
            Mehmet: Bu hafta bitiyor.
            """))

        let meetingID = outcome.meetingID
        #expect(created == meetingID, "arayüz satır açılır açılmaz haberdar edildi")
        let loaded = try await store.load(meetingID)
        #expect(loaded?.segments.count == 2, "transkript satırları yazıldı")
        #expect(loaded?.meeting.status == MeetingRecord.Status.processing.rawValue,
                "satır işlenmeyi bekliyor")
        #expect((loaded?.meeting.duration ?? 0) > 0, "süre son replikten hesaplandı")
        #expect(loaded?.meeting.audioPath == nil, "sesi olmayan toplantı")
        if case .transcript = outcome {} else {
            Issue.record("transkript içe aktarımı hattı özetlemeden başlatmalı")
        }
    }

    /// Çözümlenemeyen girdi sessizce boş bir toplantı bırakmaz.
    @Test
    func cozumlenemeyenMetinTurkceHataVerir() async throws {
        let database = try OraDatabase(path: ":memory:")
        let store = MeetingStore(database: database)
        let importer = MeetingImporter(store: store, settings: isolatedSettings())

        await #expect(throws: OraError.self) {
            try await importer.perform(.transcriptText("   "))
        }
        let meetings = try await store.list()
        #expect(meetings.isEmpty, "yarım toplantı satırı bırakılmadı")
    }

    /// Dosya adı geçici başlıktır; hat kendi başlığını üretene kadar kullanıcı
    /// listede tanıdık bir ad görür.
    @Test
    func dosyaAdiBaslikOlur() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Bordro görüşmesi.txt", directoryHint: .notDirectory)
        try """
            Ayşe: Bordro çalışması bitti mi?
            Mehmet: Bu hafta bitiyor.
            """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try OraDatabase(path: ":memory:")
        let store = MeetingStore(database: database)
        let importer = MeetingImporter(store: store, settings: isolatedSettings())

        let outcome = try await importer.perform(.transcriptFile(url))
        let loaded = try await store.load(outcome.meetingID)
        #expect(loaded?.meeting.title == "Bordro görüşmesi")
    }

    // MARK: - Ses

    /// İçe aktarılan ses tek kanala indirilir ve 16 kHz yazılır: hattın
    /// tamamı (tepe ölçümü, kanal ayırma, oynatıcı) tek biçim görür.
    @Test
    func sesTekKanalaVe16kHzeCevrilir() async throws {
        let source = try makeStereoWAV(seconds: 2, sampleRate: 44_100)
        let target = FileManager.default.temporaryDirectory
            .appending(path: "ora-import-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }

        let reported = ProgressLog()
        let duration = try await AudioImport.convert(source, to: target) { reported.add($0) }

        #expect(abs(duration - 2) < 0.1, "süre korundu")
        let written = try AVAudioFile(forReading: target)
        #expect(written.processingFormat.channelCount == 1, "tek kanal")
        #expect(written.fileFormat.sampleRate == AudioImport.sampleRate)
        #expect(reported.values.last == 1, "ilerleme sonuna kadar bildirildi")
    }

    /// İçinde ses olmayan dosya Türkçe hata verir, boş bir WAV bırakmaz.
    @Test
    func sessizOlmayanDosyaTurkceHataVerir() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ora-import-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        try Data("bu bir ses dosyası değil".utf8).write(to: source)
        let target = FileManager.default.temporaryDirectory
            .appending(path: "ora-import-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }

        await #expect(throws: OraError.self) {
            try await AudioImport.convert(source, to: target) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)),
                "yarım çıktı diskte bırakılmadı")
    }

    /// Mono dosyada `Channel.mic` şeridi istemek hem dizi sınırını aşardı hem
    /// de bütün konuşmayı "Ben" damgalardı.
    @Test
    func monoDosyaTekKanalOlarakCozulur() {
        #expect(SpeechTranscription.channels(in: 1, from: Channel.allCases) == [.system])
        #expect(SpeechTranscription.channels(in: 1, from: [.mic]) == [.system])
        #expect(SpeechTranscription.channels(in: 2, from: Channel.allCases) == Channel.allCases)
        #expect(SpeechTranscription.peak(of: .system, in: [0.4]) == 0.4,
                "mono dosyada her kanal tek şeridi gösterir")
    }

    // MARK: - Noktalama

    /// İçe aktarılan döküm zaten noktalıdır; adım orada kazanç sağlamadan
    /// dakikalar sürer ve her çağrı bir guardrail kumarıdır.
    @Test
    func noktaliMetinYenidenNoktalanmaz() {
        let imported = TranscriptParser.parse("""
            Ayşe: Bordro çalışması bu hafta bitiyor.
            Mehmet: Matrahlar hazır, kesinti kaldı.
            Ayşe: Cuma günü toplanalım mı?
            """)
        #expect(FoundationIntelligence.isPunctuated(imported))

        let dictated = [
            "bordro çalışması bu hafta bitiyor",
            "matrahlar hazır kesinti kaldı",
            "cuma günü toplanalım mı",
        ].enumerated().map { index, text in
            Segment(channel: .system, speaker: "Katılımcı", text: text,
                    start: Double(index), end: Double(index) + 1,
                    confidence: nil, words: [])
        }
        #expect(!FoundationIntelligence.isPunctuated(dictated),
                "Türkçe dikte çıktısı noktasız gelir — adım atlanmamalı")
    }

    // MARK: - Uçtan uca

    /// İçe aktarılan transkript hattın **özetleme** ucundan girer: toplantı
    /// listede görünür, ekranda seçili olur ve özeti üretilir.
    @Test
    func iceAktarilanTranskriptOzetlenir() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "içe", step: .milliseconds(1)))

        await h.controller.importSource(.transcriptText("""
            Ayşe: Bordro çalışması bitti mi?
            Mehmet: Bu hafta bitiyor.
            """))

        #expect(h.controller.meetings.count == 1)
        let meetingID = try #require(h.controller.selection, "içe aktarılan toplantı seçildi")
        #expect(h.controller.summary != nil, "özet üretildi")
        #expect(h.controller.transcript.count == 2)
        let loaded = try await h.store.load(meetingID)
        #expect(loaded?.meeting.status == MeetingRecord.Status.ready.rawValue,
                "hat bitince toplantı hazır")
        #expect(loaded?.summary != nil, "özet veritabanına yazıldı")
    }

    /// Kayıt sürerken içe aktarma kapısı kapalıdır — ikinci bir hat aynı
    /// Speech ve Foundation Models yolunu paylaşır.
    @Test
    func kayitSurerkenIceAktarmaYapilmaz() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "içe", step: .milliseconds(1)))
        await h.controller.start()
        #expect(h.controller.isRecording)
        #expect(!h.controller.canImport)

        await h.controller.importSource(.transcriptText("Ayşe: Bir şey."))
        #expect(h.controller.meetings.count == 1, "yalnızca kayıt satırı var")
    }

    // MARK: - Yardımcılar

    /// Testin `OraSettings.shared`'a dokunmaması için izole depo.
    private func isolatedSettings() -> OraSettings {
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OraSettings(defaults: defaults)
    }

    /// 44,1 kHz stereo bir WAV üretir — içe aktarmanın çevireceği tipik kaynak.
    private func makeStereoWAV(seconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ora-source-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: frames))
        buffer.frameLength = frames
        for lane in 0 ..< Int(file.processingFormat.channelCount) {
            guard let data = buffer.floatChannelData?[lane] else { continue }
            for frame in 0 ..< Int(frames) {
                data[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate)) * 0.3
            }
        }
        try file.write(from: buffer)
        return url
    }
}
