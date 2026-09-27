import Foundation

/// ARCHITECTURE.md'deki `Pipeline` katmanı: Capture'ın bıraktığı ses
/// dosyasından transkript, noktalama, özet ve konu bloklarını üretir ve
/// veritabanına yazar.
///
/// **Bu tip görünüm durumu tanımaz.** `selection` diye bir kavramı yok, hangi
/// toplantının ekranda olduğunu bilmez ve bilmemesi gerekir: ürettiği her şeyi
/// `meetingID` taşıyan `PipelineEvent` olarak yayar, süzmeyi arayüz yapar.
/// Eskiden hat doğrudan yayınlanan duruma yazıyordu ve her yazımın önünde elle
/// konmuş bir `onScreen` kapısı gerekiyordu (REFACTOR.md §2).
///
/// Hâlâ ana aktörde: işaret artık modülün varsayılanı
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), bu tip yalnızca sırayı
/// yürütüyor. Ağır adımlar — tam geçiş, noktalama, özetleme — `Transcribing` ve
/// `Intelligent` sözleşmelerinde **`@concurrent`** işaretli olduğu için ana
/// aktörün dışında koşar; `oraTests/IsolationTests` bunu ölçer.
/// `actor`'a çevirmek ayrı bir adımdır ve davranışı değiştirmez.
///
/// İşlem hattı sırası **CLAUDE.md'de sabittir**; buradaki numaralı yorumlar
/// onu izler.
final class MeetingPipeline {

    /// Dil paketi hazırlığı. Gerçek Speech varlıklarına dokunduğu için
    /// enjekte edilebilir — testte kapatılır, yoksa ölçüm makinede kurulu dil
    /// paketlerine bağımlı olur.
    typealias LocalePreparation =
        @Sendable (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void
    /// Konuşulan dili tanıyan bir Apple API'si yok; "otomatik" sesin ilk
    /// bölümünü kurulu adaylarla çözüp güven skorlarını karşılaştırır.
    typealias LocaleDetection = @Sendable (URL) async -> Locale

    static let defaultLocalePreparation: LocalePreparation = { locale, progress in
        let module = SpeechTranscription.makeTranscriber(locale: locale, live: false)
        try await TranscriptionLocale.ensureInstalled(locale, module: module,
                                                      progress: progress)
    }

    static let defaultLocaleDetection: LocaleDetection = { url in
        await TranscriptionLocale.detect(url: url, channel: .mic)
    }

    private let store: MeetingStore
    private let vocabularyStore: VocabularyStore
    private let transcription: any Transcribing
    private let intelligence: any Intelligent
    /// İsteğe bağlı ikinci motor. Kurulu değilse `engine` ona hiç bakmaz;
    /// testte de öyle — model indirilmediği için Apple yolu koşar.
    private let localIntelligence: any Intelligent
    private let settings: OraSettings
    /// Konuşmacı ayrımı. Tam geçişten sonra, noktalamadan önce koşar.
    private let diarizer: any Diarizing

    /// Özeti hangi motor üretecek?
    ///
    /// Karar **burada** verilir çünkü ayarı okuyan ve özeti başlatan yer
    /// burası; `Intelligent`'ın kendisi ana aktörün dışında koşuyor ve ayara
    /// senkron bakamaz. Yerel motor seçili ama model kurulu değilse sessizce
    /// Apple'a düşülür — özet üretmemektense zayıf özet üretmek yeğdir ve
    /// kullanıcı Ayarlar'da eksik modeli zaten görüyor.
    private var engine: any Intelligent {
        guard settings.summaryEngine == .local,
              localIntelligence.availability.isAvailable else { return intelligence }
        return localIntelligence
    }
    private let deferReason: @Sendable () -> PowerState.DeferReason?
    private let prepareLocale: LocalePreparation
    private let detectLocale: LocaleDetection

    /// Olay dinleyicileri. **Senkron ve ana aktörde**: sıra korunur ve
    /// `await pipeline.…` döndüğünde arayüz durumu zaten güncellenmiş olur.
    /// `AsyncStream` bir tur gecikme koyar ve "işlem bitti ama ekran hâlâ eski"
    /// penceresi açardı.
    private var observers: [(PipelineEvent) -> Void] = []

    /// Şu an koşan toplantılar. Aşama **veritabanından türetilmez**: tam geçiş
    /// segmentleri çoktan yazdığı için yarım hâlden türetince işlenen
    /// toplantıya dönüldüğünde animasyon kayboluyordu (RESEARCH.md §27).
    private var running: Set<Int64> = []

    /// Bağlı sağlayıcı (Faz 11). Hat ayarları ve anahtarları tanımaz;
    /// denetleyici `ConnectionCenter`'a bağlar. nil dönerse (seçili değil,
    /// hazır değil, toplantı kilitli) cihazdaki motor kullanılır.
    var cloudEngine: ((Int64) async -> (any Intelligent)?)?
    /// Bağlı sağlayıcı kurulu ve onaylı mı — arayüz kapıları için.
    var cloudReady: () -> Bool = { false }

    /// Bu toplantının özetini ve sohbetini hangi motor üretecek?
    func engine(for meetingID: Int64?) async -> any Intelligent {
        if settings.summaryEngine == .cloud, let meetingID,
           let cloud = await cloudEngine?(meetingID) {
            return cloud
        }
        return engine
    }

    /// Arayüz kapıları seçili motorun durumuna bakar.
    var modelAvailability: ModelAvailability {
        switch settings.summaryEngine {
        case .local: localIntelligence.availability
        case .cloud: cloudReady() ? .available : intelligence.availability
        case .apple: intelligence.availability
        }
    }

    /// Hat **herhangi bir** toplantı için koşuyor mu. Yetki kapıları buna bakar:
    /// ikinci bir hat aynı Speech ve Foundation Models yolunu paylaşır.
    var isRunning: Bool { !running.isEmpty }

    init(store: MeetingStore,
         vocabularyStore: VocabularyStore,
         transcription: any Transcribing,
         intelligence: any Intelligent,
         localIntelligence: (any Intelligent)? = nil,
         diarizer: (any Diarizing)? = nil,
         settings: OraSettings,
         deferReason: @escaping @Sendable () -> PowerState.DeferReason?
            = PowerState.deferReason,
         prepareLocale: LocalePreparation? = nil,
         detectLocale: LocaleDetection? = nil) {
        self.store = store
        self.vocabularyStore = vocabularyStore
        self.transcription = transcription
        self.intelligence = intelligence
        self.localIntelligence = localIntelligence ?? LocalIntelligence(fallback: intelligence)
        self.diarizer = diarizer ?? FluidDiarizer()
        self.settings = settings
        self.deferReason = deferReason
        self.prepareLocale = prepareLocale ?? Self.defaultLocalePreparation
        self.detectLocale = detectLocale ?? Self.defaultLocaleDetection
    }

    /// Hattın olaylarına abone olur. Birden çok tüketici olabilir: arayüzün
    /// yanı sıra ileride hafıza, otomasyon ve MCP de buraya bağlanır.
    func observe(_ handler: @escaping (PipelineEvent) -> Void) {
        observers.append(handler)
    }

    private func emit(_ kind: PipelineEvent.Kind, _ meetingID: Int64) {
        let event = PipelineEvent(meetingID: meetingID, kind: kind)
        for observer in observers { observer(event) }
    }

    private func stage(_ stage: PipelineStage, _ meetingID: Int64) {
        if stage.isActive { running.insert(meetingID) } else { running.remove(meetingID) }
        emit(.stage(stage), meetingID)
    }

    // MARK: - Adım 3: kayıt sonrası tam transkripsiyon geçişi

    func fullPass(meetingID: Int64, url: URL) async {
        // Hat hangi yoldan çıkarsa çıksın aşama açık kalmaz: takılı bir
        // animasyon, hata mesajından daha kötü bir hata modudur.
        defer { if running.contains(meetingID) { stage(.done, meetingID) } }
        // Ses artık diskte; oynatıcı toplantıyı yeniden seçmeye gerek kalmadan
        // bu kayda bağlanabilir.
        emit(.audio(url), meetingID)
        stage(.preparingLanguage, meetingID)

        let locale: Locale
        if let chosen = settings.transcriptionLanguage.locale {
            locale = chosen
        } else {
            locale = await detectLocale(url)
        }

        do {
            Log.debug(.transcribe, "Tam geçiş: dil hazırlanıyor (\(locale.identifier))")
            try await prepareLocale(locale) { [weak self] value in
                Task { @MainActor in self?.stage(.downloadingLanguage(value), meetingID) }
            }
            stage(.transcribing(0), meetingID)
            let words = (try? await vocabularyStore.activeWords()) ?? []
            Log.debug(.transcribe, "Tam geçiş: \(words.count) sözlük terimi, ses açılıyor")
            let transcribed = try await transcription.transcribe(
                url: url, locale: locale, vocabulary: words
            ) { [weak self] value in
                Task { @MainActor in self?.stage(.transcribing(value), meetingID) }
            }
            // 3b — Konuşmacı ayrımı
            let segments = await separateSpeakers(meetingID: meetingID, url: url,
                                                  segments: transcribed)
            emit(.transcript(segments), meetingID)
            try? await store.replaceTranscript(meetingID, segments: segments)
            // Ses izinden tanınan adlar katılımcı olarak yazılır (elle
            // adlandırmayla aynı eşitleme).
            if segments.contains(where: { !MeetingStore.isChannelLabel($0.speaker) }) {
                try? await store.syncTranscriptParticipants(meetingID)
            }
            Log.info(.transcribe, "Tam geçiş bitti — \(segments.count) segment, "
                     + "\(locale.identifier)")
            await summarize(meetingID: meetingID, segments: segments)
        } catch {
            stage(.idle, meetingID)
            Log.error(.transcribe, "Tam geçiş başarısız (\(locale.identifier))", error)
            // Ham ses korunur: "Yeniden dene" bu dosyayı işler.
            emit(.retryable(url), meetingID)
            emit(.failed(error as? OraError ?? .transcriptionFailed(underlying: error)),
                 meetingID)
        }
    }

    // MARK: - Adım 3b: konuşmacı ayrımı

    /// Tek kanalın konuşmacılarını ayırır ve satırları kelime düzeyinde böler.
    ///
    /// **En iyi çabadır**, noktalama gibi: başarısız olursa transkript kanal
    /// etiketleriyle ("Ben" / "Katılımcı") olduğu gibi kalır, hat durmaz.
    /// Hangi kanalın ayrılacağı ve kümelerin adı `SpeakerSeparation`'dadır;
    /// burada yalnızca sıra yürütülür.
    private func separateSpeakers(meetingID: Int64, url: URL,
                                  segments: [Segment]) async -> [Segment] {
        guard settings.speakerSeparationEnabled, diarizer.isAvailable,
              let channel = SpeakerSeparation.channel(for: segments) else { return segments }
        stage(.separatingSpeakers(0), meetingID)
        do {
            let result = try await diarizer.turns(url: url, channel: channel) { [weak self] value in
                Task { @MainActor in self?.stage(.separatingSpeakers(value), meetingID) }
            }
            // Yalnızca gürültü sayılmayan kümeler tanınmaya aday.
            let present = Set(SpeakerSeparation.significant(result.turns).map(\.speaker))
            let candidates = result.embeddings.filter { present.contains($0.key) }

            var known: [String: String] = [:]
            if settings.voiceMemoryEnabled {
                var people = (try? await store.voiceprints()) ?? [:]
                // Uzak kanalda kullanıcının kendi sesi aday değildir — orada
                // yalnızca hoparlörden sızan yankısı olabilir.
                if channel == .system { people[VoicePrint.me] = nil }
                known = VoiceMatcher.assign(clusters: candidates, people: people)
            }

            let (separated, labels) = SpeakerSeparation.separate(
                result.turns, to: segments, channel: channel, known: known)
            // Kümelerin sesi **verilen etiketle** saklanır: kullanıcı bir
            // etiketi adlandırınca kime ait olduğu buradan bilinir.
            var byLabel: [String: [Float]] = [:]
            for (cluster, label) in labels {
                if let embedding = result.embeddings[cluster] { byLabel[label] = embedding }
            }
            try? await store.saveSpeakerEmbeddings(meetingID, channel: channel,
                                                   embeddings: byLabel)
            if settings.voiceMemoryEnabled, channel == .system {
                await learnOwnVoice(meetingID: meetingID, url: url, segments: segments)
            }

            let names = Set(separated.filter { $0.channel == channel }.map(\.speaker))
            Log.info(.transcribe, "Konuşmacılar ayrıldı — \(channel.databaseValue) kanalında "
                     + "\(names.count) etiket, \(known.count) tanınan kişi, "
                     + "\(segments.count) → \(separated.count) satır")
            return separated
        } catch {
            Log.warning(.transcribe, "Konuşmacı ayrımı atlandı: \(error.localizedDescription)")
            return segments
        }
    }

    /// Kullanıcının kendi sesinden bu kadar örnek birikince artık öğrenilmez.
    static let ownVoiceSamples = 5
    /// Mikrofonda en çok konuşan küme en az bu kadar konuşmalı.
    static let ownVoiceMinimumSpeech: TimeInterval = 20

    /// Uzak toplantıda mikrofon kanalı kullanıcının kendisidir: en çok konuşan
    /// kümenin sesi "Ben" olarak öğrenilir. Yüz yüze toplantıda odadaki
    /// kişiler aynı mikrofonu paylaştığında kaydı tutan böyle tanınır.
    /// Birkaç örnekten sonra durur — her kayıtta ikinci bir ayrım koşmaz.
    private func learnOwnVoice(meetingID: Int64, url: URL, segments: [Segment]) async {
        guard segments.contains(where: { $0.channel == .mic }),
              ((try? await store.voiceprintCount(person: VoicePrint.me)) ?? 0)
                  < Self.ownVoiceSamples else { return }
        do {
            let mic = try await diarizer.turns(url: url, channel: .mic) { _ in }
            var speech: [String: TimeInterval] = [:]
            for turn in mic.turns { speech[turn.speaker, default: 0] += turn.duration }
            guard let owner = speech.max(by: { $0.value < $1.value }),
                  owner.value >= Self.ownVoiceMinimumSpeech,
                  let embedding = mic.embeddings[owner.key] else { return }
            try await store.addVoiceprint(person: VoicePrint.me, meetingID: meetingID,
                                          embedding: embedding)
            Log.info(.transcribe, "Kendi sesiniz öğrenildi (\(Int(owner.value)) sn)")
        } catch {
            Log.warning(.transcribe, "Kendi ses izi öğrenilemedi: \(error.localizedDescription)")
        }
    }

    // MARK: - Adım 4-7: noktalama, özet, kayıt, bildirim

    /// - Parameter variation: kullanıcı özeti beğenmeyip **yeniden ürettiğinde**
    ///   açılır; örnekleme serbestleşir ve başlık yeniden üretilmez.
    func summarize(meetingID: Int64, segments: [Segment], variation: Bool = false) async {
        defer { if running.contains(meetingID) { stage(.done, meetingID) } }

        // Kayıt bitince işlem hemen başlar. **Tek istisna:** düşük güç modu veya
        // termal baskı — o zaman otomatik başlatılmaz, kullanıcıya sorulur.
        if let reason = deferReason() {
            emit(.deferred(reason), meetingID)
            emit(.notice(reason.turkishMessage + ". " + reason.turkishDetail), meetingID)
            await finish(meetingID, ozet: nil, topics: [], save: true)
            Log.info(.pipeline, "Özetleme ertelendi: \(reason.turkishMessage)")
            return
        }
        emit(.deferCleared, meetingID)

        // Motor toplantı başına seçilir: bağlı sağlayıcı kilitli toplantıyı
        // hiç görmez (Bağlantı Kuralları §6).
        let engine = await engine(for: meetingID)
        let availability = engine.availability
        guard availability.isAvailable else {
            emit(.notice(availability.turkishMessage + ". " + availability.turkishDetail),
                 meetingID)
            await finish(meetingID, ozet: nil, topics: [], save: true)
            Log.warning(.intelligence, "Özetleme atlandı: \(availability.turkishMessage)")
            return
        }

        // 4 — Noktalama restorasyonu (zorunlu adım)
        //
        // Hattın beslendiği metin **yereldir**: `segments` çağrıldığı anda
        // verilmiştir ve seçim değişse bile değişmez.
        var working = segments
        stage(.punctuating(0), meetingID)
        do {
            let punctuated = try await engine.restorePunctuation(segments) { [weak self] value in
                Task { @MainActor in self?.stage(.punctuating(value), meetingID) }
            }
            working = punctuated
            emit(.transcript(punctuated), meetingID)
            try? await store.replaceTranscript(meetingID, segments: punctuated)
        } catch {
            // Noktalama bir iyileştirmedir; başarısız olursa orijinal metin korunur.
            Log.warning(.intelligence, "Noktalama atlandı: \(error.localizedDescription)")
        }

        // 5 — Map-reduce özetleme
        stage(.summarizing(0), meetingID)
        // Tarih ve katılımcılar **işlenen** toplantıdan okunur; ekrandaki
        // toplantıdan alınırsa son tarihler yanlış güne bağlanır.
        let record = try? await store.load(meetingID)
        let people = (try? await store.calendarParticipants(meetingID)) ?? []
        // Kullanıcının transkriptte adlandırdığı konuşmacılar da kapalı
        // listeye girer. Bu liste **yalnızca doğrulamada** kullanılır
        // (`resolvedPerson`); isteme roster yazılmaz — ölçüldü, model onu
        // kısıt değil menü gibi kullanıyor (RESEARCH.md §23.5).
        let named = (try? await store.transcriptParticipants(meetingID)) ?? []
        var produced: Ozet?
        var producedTopics: [TopicSegment] = []
        do {
            let context = SummaryContext(
                meetingDate: record?.meeting.date ?? Date(),
                participants: people + named + [settings.userDisplayName]
                    .compactMap { $0.isEmpty ? nil : $0 },
                userName: settings.userDisplayName.isEmpty ? nil : settings.userDisplayName,
                // İçe aktarılan dökümde satırlar gerçek adlarla başlıyor;
                // orada "Ben kaydı tutan kişidir" cümlesi zarar veriyor (§33).
                hasNamedSpeakers: working.contains {
                    !MeetingStore.isChannelLabel($0.speaker)
                },
                hasRecorderLines: working.contains { $0.speaker == Channel.mic.speaker },
                detail: settings.summaryDetail)
            let result: SummaryResult
            do {
                result = try await engine.summarize(
                    working, context: context, variation: variation) { [weak self] value in
                    Task { @MainActor in self?.stage(.summarizing(value), meetingID) }
                }
            } catch let error as OraError
                        where engine is CloudIntelligence && intelligence.availability.isAvailable {
                // Kural 9: sağlayıcıya ulaşılamazsa iş cihazda yapılır ve
                // kullanıcıya söylenir.
                emit(.notice(error.turkishDetail + " Özet cihazda üretildi."), meetingID)
                Log.warning(.intelligence, "Bağlı sağlayıcı başarısız, cihaza düşüldü: "
                            + error.turkishDetail)
                result = try await intelligence.summarize(
                    working, context: context, variation: variation) { [weak self] value in
                    Task { @MainActor in self?.stage(.summarizing(value), meetingID) }
                }
            }
            produced = result.ozet
            producedTopics = result.topics
            emit(.summary(result.ozet, result.topics), meetingID)
            if result.skippedChunks > 0 {
                // Sessiz kalite düşüşü yok: bir bölüm özetlenemediyse söylenir.
                emit(.notice("\(result.skippedChunks) bölüm özetlenemedi; "
                             + "özet eksik olabilir. Transkript tam."), meetingID)
            }
            Log.info(.intelligence, "Özet hazır — \(result.ozet.kararlar.count) karar, "
                     + "\(result.ozet.aksiyonlar.count) aksiyon, "
                     + "\(result.topics.count) konu, \(result.skippedChunks) atlanan parça")
        } catch let error as OraError {
            emit(.notice(error.turkishMessage + ". " + error.turkishDetail), meetingID)
            Log.error(.intelligence, "Özetleme başarısız", error)
        } catch {
            emit(.notice("Özet oluşturulamadı. Transkript korundu."), meetingID)
            Log.error(.intelligence, "Özetleme başarısız", error)
        }

        // Başlık önceliği: takvim etkinlik adı → Foundation Models'ın ürettiği
        // başlık → tarih/saat. Pencere başlığı **okunmaz**.
        //
        // Takvim bağı toplantı kaydından okunur (`calendarEventId`), kayıt
        // oturumunun `activeEvent`'inden değil: "Yeniden dene" ve "Şimdi
        // özetle" yollarında `activeEvent` her zaman nil olduğu için takvimden
        // gelen başlığın üstüne üretilmiş başlık yazılabiliyordu.
        //
        // Yeniden özetlemede başlık **üretilmez**: toplantının adı zaten var ve
        // kullanıcı onu elle değiştirmiş olabilir.
        if record?.meeting.calendarEventId == nil, !variation,
           let title = await engine.generateTitle(from: working, topics: producedTopics) {
            try? await store.updateTitle(meetingID, title: title)
        }

        // 6 — SQLite güncelle. Üretim başarısızsa (`produced == nil`) eldeki
        // özet **korunur**: yeniden üretim denemesi var olan özeti, konuları ve
        // işaretlenmiş aksiyonları silmez.
        await finish(meetingID, ozet: produced, topics: producedTopics,
                     save: produced != nil || !variation)
    }

    /// Ortak kapanış: özeti yaz, durumu `ready` yap, sesi sıkıştır, aksiyonları
    /// yayınla ve bildirimi tetikle.
    private func finish(_ meetingID: Int64, ozet: Ozet?, topics: [TopicSegment],
                        save: Bool) async {
        if save {
            try? await store.saveSummary(meetingID, ozet: ozet, topics: topics)
        }
        try? await store.markReady(meetingID)
        let reloaded = try? await store.load(meetingID)
        // Ses ancak transkript ve özet hazırken sıkıştırılır (opt-in).
        if let record = reloaded?.meeting { await compressAudioIfNeeded(record) }
        if let reloaded { emit(.actions(reloaded.actions), meetingID) }
        stage(.done, meetingID)
        emit(.storeChanged, meetingID)

        // 7 — Kullanıcıya bildir. Başlık **işlenen** toplantının kaydından
        // okunur; eskiden arayüzün listesinden alınıyordu.
        if let title = reloaded?.meeting.title {
            emit(.finished(title: title), meetingID)
        }
    }

    /// Ayarlardaki sıkıştırma açıksa sesi AAC'ye çevirir. Transkripsiyon ve
    /// özet bittikten **sonra** çalışır; hata verirse ses olduğu gibi kalır.
    ///
    /// Dosya yolu **işlenen** toplantının kaydından okunur.
    private func compressAudioIfNeeded(_ meeting: MeetingRecord) async {
        guard settings.compressAudio, let meetingID = meeting.id,
              let url = Self.existingAudio(meeting),
              url.pathExtension.lowercased() == "wav" else { return }
        do {
            let compressed = try await AudioArchive.compress(url)
            try? await store.setAudioPath(meetingID, path: compressed.path(percentEncoded: false))
            emit(.audio(compressed), meetingID)
        } catch {
            Log.warning(.capture, "Ses sıkıştırılamadı, WAV korundu: \(error.localizedDescription)")
        }
    }

    /// Ses dosyası hâlâ diskte mi?
    static func existingAudio(_ meeting: MeetingRecord) -> URL? {
        guard let path = meeting.audioPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
