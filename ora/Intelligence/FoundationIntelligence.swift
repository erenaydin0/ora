import Foundation
import FoundationModels

/// `FoundationModels` (Apple'ın cihaz üstü ~3B modeli) üzerine kurulu
/// noktalama ve özetleme.
///
/// Bağlam penceresi **4096 token**; Türkçe'de kabaca 4 karakter ≈ 1 token
/// (RESEARCH.md §3). Bu yüzden her uzun girdi map-reduce edilir ve
/// **her parça için yeni `LanguageModelSession`** açılır — oturum tekrar
/// kullanılırsa geçmiş bağlamı yiyip pencereyi taşırır.
struct FoundationIntelligence: Intelligent {

    /// Talimat her çağrıda aynıdır.
    ///
    /// Genişletilmiş hâli guardrail'e takılmıyor (RESEARCH.md §23) — §15.1'de
    /// ölçülen guardrail sorunu noktalama istemine ve konuşmacı önekine özgüydü.
    private static let instructions = """
        Sen bir toplantı asistanısın. Türkçe toplantıda Türkçe yanıt ver.
        Yalnızca metinde geçen bilgiyi kullan; çıkarım yapma, uydurma.
        Sayıları, tarihleri ve özel isimleri aynen koru.
        """

    var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .modelNotReady
        }
    }

    // MARK: - Noktalama restorasyonu

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        guard availability.isAvailable, !segments.isEmpty else { return segments }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.punctuationLimit)
        var restored: [Segment] = []
        restored.reserveCapacity(segments.count)

        for (index, chunk) in chunks.enumerated() {
            restored.append(contentsOf: await punctuate(chunk))
            progress(Double(index + 1) / Double(chunks.count))
        }
        return restored
    }

    /// Bir parçayı noktalar. Model metni bozarsa **o satır olduğu gibi kalır** —
    /// noktalama bir iyileştirmedir, kelime kaybetme pahasına yapılmaz.
    ///
    /// **Konuşmacı öneki ("Ben:", "Katılımcı:") bu isteme EKLENMEZ.** Ölçüldü
    /// (RESEARCH.md §15.1): önekli noktalama istemi 8 denemenin 6'sında
    /// `guardrailViolation` veriyor, öneksiz 8/8 geçiyor. Noktalama için
    /// konuşmacı bilgisine zaten ihtiyaç yok.
    private func punctuate(_ chunk: [Segment]) async -> [Segment] {
        let numbered = chunk.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")

        let strict = """
        Aşağıdaki numaralı satırlara noktalama işaretleri ve büyük harf düzeltmesi ekle.
        Kurallar:
        - Kelimeleri DEĞİŞTİRME, EKLEME veya SİLME. Yalnızca noktalama ve büyük/küçük harf.
        - Satır sayısını ve numaralandırmayı aynen koru.
        - Yorum, açıklama veya başlık ekleme.

        \(numbered)
        """
        // Guardrail tetiklenirse daha yalın bir istemle bir kez daha denenir.
        let plain = """
        Aşağıdaki satırlara noktalama işaretleri ekle. Satır sayısını ve
        numaralandırmayı koru.

        \(numbered)
        """

        do {
            let content = try await respondWithRetry(strict: strict, plain: plain)
            let lines = Self.numberedLines(content)
            guard lines.count == chunk.count else {
                Log.warning(.intelligence, "Noktalama parçası atlandı: satır sayısı "
                            + "uyuşmadı (\(lines.count) ≠ \(chunk.count))")
                return chunk
            }
            return zip(chunk, lines).map { segment, line in
                // Kelime kimliği korunmadıysa orijinali tut.
                guard Self.sameWords(segment.text, line) else {
                    Log.debug(.intelligence, "Noktalama reddedildi (kelime değişmiş): "
                              + "\(segment.text.prefix(40))…")
                    return segment
                }
                return Segment(channel: segment.channel, speaker: segment.speaker,
                               text: line, start: segment.start, end: segment.end,
                               confidence: segment.confidence, words: segment.words)
            }
        } catch {
            Log.warning(.intelligence, "Noktalama parçası başarısız: \(error.localizedDescription)")
            return chunk
        }
    }

    /// Her parça için **yeni oturum** — oturum tekrar kullanılırsa geçmiş bağlam
    /// birikir ve 4096 token penceresi taşar.
    private func respondWithRetry(strict: String, plain: String) async throws -> String {
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(to: strict).content
        } catch let error as LanguageModelSession.GenerationError {
            guard case .guardrailViolation = error else { throw error }
            Log.debug(.intelligence, "Noktalama istemi guardrail'e takıldı, yalın istemle "
                      + "tekrar deneniyor")
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(to: plain).content
        }
    }

    // MARK: - Map-reduce özetleme

    /// Toplam konu sayısını 5-7 aralığında tutmak için parça başına hedef.
    /// Ölçüldü (`circleback-notes/`): iyi bir toplantı notu 18 dakikalık
    /// toplantıda da 66 dakikalıkta da 5-7 bölüm veriyor — bölüm sayısı
    /// süreyle değil, konuşmanın konu sayısıyla ölçekleniyor.
    static func topicTarget(chunkCount: Int) -> Int {
        guard chunkCount > 0 else { return 1 }
        return max(1, min(4, Int((6.0 / Double(chunkCount)).rounded(.up))))
    }

    func summarize(_ segments: [Segment],
                   context: SummaryContext,
                   progress: @Sendable @escaping (Double) -> Void) async throws
        -> SummaryResult {
        guard availability.isAvailable else {
            throw OraError.modelUnavailable(reason: availability.turkishMessage)
        }
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Özetlenecek metin yok")
        }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.summaryLimit)
        let target = Self.topicTarget(chunkCount: chunks.count)
        Log.info(.intelligence, "Özetleme: \(chunks.count) parça, "
                 + "\(segments.count) segment, parça başına \(target) konu hedefi")

        // MAP — her parça kendi oturumunda konularına ayrılır.
        //
        // Eskiden burada **iki** çağrı vardı (serbest metin özet + ayrı başlık)
        // ve özet metni birleştirmeden sonra çöpe gidiyordu. Tek yapılandırılmış
        // çağrı hem daha ucuz hem de konu gövdesini kalıcı kılıyor.
        var topics: [TopicSegment] = []
        var aksiyonlar: [Ozet.Aksiyon] = []
        var skipped = 0
        for (index, chunk) in chunks.enumerated() {
            if let parca = await chunkTopics(of: TranscriptChunker.render(chunk),
                                             target: target, context: context),
               let first = chunk.first, let last = chunk.last {
                // `@Guide(.maximumCount:)` derleme zamanı sabiti; istemdeki
                // "en fazla N konu" ölçümde tutmadı (23 bölüm çıktı, hedef 5-7).
                // Kesin sınır kodda uygulanır.
                for konu in parca.konular.prefix(target) {
                    let baslik = konu.baslik.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !baslik.isEmpty else { continue }
                    topics.append(TopicSegment(title: baslik,
                                               bullets: Self.cleaned(konu.maddeler),
                                               start: first.start, end: last.end))
                }
                aksiyonlar.append(contentsOf: parca.aksiyonlar
                    .filter { !Self.isStatusNotTask($0.gorev) }
                    .map {
                        Self.validated($0, topicTitles: parca.konular.map(\.baslik),
                                       context: context)
                    })
            } else {
                // Sessiz yutma yok: eskiden ham 600 karakter birleştirmeye
                // giriyordu ve kullanıcı bunu hiç görmüyordu.
                skipped += 1
                Log.warning(.intelligence, "Parça \(index + 1) özetlenemedi, atlandı")
            }
            // Birleştirme adımı için son %20 pay bırakılır.
            progress(Double(index + 1) / Double(chunks.count) * 0.8)
        }

        topics = Self.deduplicatedTopics(topics)
        guard !topics.isEmpty else {
            throw OraError.modelUnavailable(reason: "Toplantı özetlenemedi")
        }

        // REDUCE — birleştirme artık paraphrase değil **konu notları** görüyor.
        // Uzunsa madde budanır; özetin özetini almak sayıları ve isimleri
        // eritiyordu.
        let combined = Self.fit(topics, limit: TranscriptChunker.summaryLimit)

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            // Birleştirme **aksiyon üretmez** — sorumlu kişiyi bilemez.
            let response = try await session.respond(to: """
                Aşağıda bir toplantının konu konu notları var. Bunlardan
                toplantının 4-6 maddelik genel bakışını ve alınan kararları çıkar.
                Kurallar:
                - Genel bakışta her madde tek cümle olsun; önce ne olduğu,
                  sonra sonucu.
                - Genel bakışa toplantının tarihini veya süresini yazma.
                - Konu başlıklarını olduğu gibi tekrar etme; ne olduğunu yaz.
                - Karar olarak yalnızca gerçekten karara bağlanmış şeyleri yaz.
                \(Self.dateLine(context))

                \(combined)
                """,
                generating: ToplantiOzeti.self)
            progress(1)
            let ozet = Ozet(genelBakis: response.content.genelBakis,
                            kararlar: response.content.kararlar,
                            aksiyonlar: aksiyonlar)
            return SummaryResult(ozet: Self.deduplicated(ozet),
                                 topics: topics,
                                 skippedChunks: skipped)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // Buraya düşmek parçalama mantığında hata olduğunu gösterir.
                throw OraError.contextOverflow
            }
            throw OraError.modelUnavailable(reason: error.localizedDescription)
        } catch {
            throw OraError.modelUnavailable(reason: error.localizedDescription)
        }
    }

    /// Bir parçayı konularına ayırır. Başarısız olursa **bir kez** daha denenir.
    private func chunkTopics(of text: String, target: Int,
                             context: SummaryContext) async -> ParcaOzeti? {
        let prompt = """
            Bu toplantı bölümünü konularına ayır. En fazla \(target) konu çıkar.
            Her konu için 2-6 kelimelik bir başlık ve o konuda konuşulanları
            anlatan maddeler yaz. Az konu isteniyorsa her konuyu daha ayrıntılı
            yaz; konuşulan her önemli noktaya bir madde ayır.
            Kurallar:
            - Her madde tek cümle olsun ve tek başına anlaşılsın.
            - Sayıları, tarihleri, firma ve kişi adlarını metinde geçtiği gibi yaz.
            - "Toplantıda konuşuldu" gibi dolgu cümle kurma; ne olduğunu yaz.
            - Kim ne üstlendiyse adıyla yaz. \(Self.selfLine(context))
            - "Ben", "Katılımcı" gibi konuşmacı etiketlerini maddeye yazma.
            Aksiyon kuralları:
            - Yalnızca birinin **açıkça üstlendiği** işleri yaz. Durum bildiren
              cümleleri ("şu çalışıyor", "şu tamamlandı") aksiyon sayma.
            - Bir bölümde hiç aksiyon olmayabilir; zorlama, boş bırak.
            - Sorumluyu metinde o işi üstlenen kişiden al; anlaşılmıyorsa
              "belirtilmedi" yaz.
            - Yapılmış işleri değil, **yapılacak** işleri yaz.
            - Bağlam alanına işin hangi konuşmadan çıktığını yaz.
            - Son tarihi yalnızca metinde açıkça geçiyorsa yaz.
            \(Self.dateLine(context))

            \(text)
            """
        for attempt in 1 ... 2 {
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                return try await session.respond(to: prompt,
                                                 generating: ParcaOzeti.self).content
            } catch {
                Log.warning(.intelligence, "Konu ayrıştırma denemesi \(attempt) "
                            + "başarısız: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Model, gerçek içeriği olmayan alanı **istemdeki en yakın metinle**
    /// dolduruyor (ölçüm: RESEARCH.md §23). İki tekrarlayan sızıntı kodda
    /// kesilir — "yapma" demek 3B modelde işe yaramıyor, hatta tetikliyor.
    ///
    ///  - `baglam` konu başlığını tekrarlıyor → düşürülür
    ///  - `sonTarih` toplantı tarihinin kendisi oluyor → "belirtilmedi"
    /// Şimdiki zaman ("kontrol ediliyor", "çalışıyor") bir görev değil, durum
    /// bildirir. Ölçüldü (RESEARCH.md §23.9): anlatım ağırlıklı bir toplantıda
    /// üretilen 12 "aksiyon"un çoğu bu kalıptaydı.
    static func isStatusNotTask(_ gorev: String) -> Bool {
        guard let last = words(of: gorev).last else { return true }
        // Şimdiki zaman: "kontrol ediliyor"
        if last.hasSuffix("yor") || last.hasSuffix("yorlar") { return true }
        // Belirli geçmiş: "belirtti", "yazdı", "kontrol etti" — olmuş bir şey
        // anlatılıyor, yapılacak bir şey değil. Fiil listesi yetmedi (ölçüm:
        // "yazdı", "etti" listede yoktu); ek kalıbının kendisi aranır.
        return Self.pastEndings.contains { last.hasSuffix($0) }
    }

    /// Türkçe belirli geçmiş 3. tekil eki. Diakritikler `words(of:)` içinde
    /// zaten düşürüldüğü için sadeleşmiş biçimler yeterli.
    private static let pastEndings = ["di", "dı", "du", "dü", "ti", "tı", "tu", "tü"]

    static func validated(_ aksiyon: Ozet.Aksiyon, topicTitles: [String],
                          context: SummaryContext) -> Ozet.Aksiyon {
        var result = aksiyon
        result.kisi = resolvedPerson(aksiyon.kisi, context: context)

        if aksiyon.baglam.split(separator: " ").count < 4
            || Self.echoesTitle(aksiyon.baglam, titles: topicTitles) {
            result.baglam = ""
        }

        if Self.isMeetingDate(aksiyon.sonTarih, context.meetingDate) {
            result.sonTarih = "belirtilmedi"
        }
        return result
    }

    /// Bağlam bir konu başlığının yeniden yazımı mı? Birebir eşleşme yetmiyor:
    /// model "Analiz Ekranı Durumu ve Yemek Parası Kalemi" başlığından
    /// "Analiz ekranı konusundan çıktı" üretiyor. Ölçüt kelime örtüşmesi:
    /// bağlamın anlamlı kelimelerinin çoğu başlıkta geçiyorsa bilgi taşımıyor.
    static func echoesTitle(_ baglam: String, titles: [String]) -> Bool {
        let filler: Set<String> = ["konusundan", "konusunda", "cikti", "cikan",
                                   "hakkinda", "ile", "ve", "bu", "icin"]
        let words = Set(words(of: baglam)).subtracting(filler)
        guard !words.isEmpty else { return true }
        return titles.contains { title in
            let titleWords = Set(Self.words(of: title))
            guard !titleWords.isEmpty else { return false }
            let shared = words.intersection(titleWords).count
            return Double(shared) / Double(words.count) >= 0.6
        }
    }

    /// Son tarih toplantının kendi tarihi mi? Model tarihi "3 Eylül 2026" ya da
    /// "Perşembe, 3 Eylül 2026" biçiminde kopyalıyor — **içerme** aranır.
    static func isMeetingDate(_ value: String, _ date: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy"
        let stamp = normalized(formatter.string(from: date))
        return !stamp.isEmpty && normalized(value).contains(stamp)
    }

    /// Türkçe küçük harfe indirip harf/rakam dışını atarak kelimelere böler.
    static func words(of text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0.folding(options: .diacriticInsensitive,
                                     locale: Locale(identifier: "tr_TR"))) }
            .filter { $0.count > 2 }
    }

    // MARK: - İstem parçaları

    /// Mikrofon kanalındaki kişi. Ad verilmemişse yalnızca "Ben" denir —
    /// bu cümle olmadan `kisi` alanı hep "belirtilmedi" geliyor (RESEARCH.md §15.2).
    static func selfLine(_ context: SummaryContext) -> String {
        guard let name = context.userName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return "\"Ben\" bu kaydı tutan kişidir." }
        return "\"Ben\" bu kaydı tutan kişidir, adı \(name)."
    }

    /// Katılımcı listesi **isteme yazılmaz.** A/B ölçüldü (RESEARCH.md §23):
    /// kapalı isim listesi verildiğinde model onu bir kısıt değil bir *menü*
    /// gibi kullanıyor, üstelik görevler belirsizleşiyor ve son tarihlere
    /// toplantı tarihi sızıyor (4/4 aksiyonda). Liste yalnızca **doğrulamada**
    /// kullanılır: model bir ad döndürdüyse listeye göre eşleştirilir.
    ///
    /// Sonuç, atıf yapamadığında "belirtilmedi" demek oluyor. Kanal ayrımı
    /// yalnızca "Ben" ve "Katılımcı" verdiği için (diarization yok) uzaktaki
    /// katılımcılar çoğu zaman ayırt edilemez; kendinden emin yanlış bir ad,
    /// boş bir alandan kötüdür.
    static func resolvedPerson(_ raw: String, context: SummaryContext) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(trimmed)
        guard !key.isEmpty else { return "belirtilmedi" }

        // Mikrofon kanalı kullanıcının kendisidir — adı biliniyorsa yazılır.
        if key == normalized("Ben") {
            return context.userName?.isEmpty == false ? context.userName! : "Ben"
        }
        // Konuşmacı etiketi bir kişi adı değil.
        if key == normalized("Katılımcı") { return "belirtilmedi" }

        // Takvimden gelen tam ada eşle: model "Merve" derse "Merve Sarı" olsun.
        // Birden çok aday varsa **eşleştirme yapılmaz** — tahmin edilmez.
        let matches = context.participants.filter {
            let candidate = normalized($0)
            return candidate == key || candidate.hasPrefix(key) || key.hasPrefix(candidate)
        }
        if matches.count == 1 { return matches[0] }
        return trimmed
    }

    /// Göreli tarihleri ("Cuma", "haftaya") mutlak tarihe çevirebilmesi için.
    static func dateLine(_ context: SummaryContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        // Örnek kelime **verilmez**: ölçümde "haftaya" örneği istemden
        // yankılanıp bütün son tarihlere yazıldı.
        return "Toplantı tarihi: \(formatter.string(from: context.meetingDate)). "
            + "Metinde geçen gün adlarını bu tarihe göre yorumla; tarih uydurma."
    }

    // MARK: - Birleştirme yardımcıları

    /// Konu notlarını birleştirme istemine sığdırır. Sığmıyorsa madde sayısı
    /// kademeli olarak budanır — **yeniden özetleme yapılmaz**, çünkü özetin
    /// özeti sayıları ve özel isimleri eritiyor.
    static func fit(_ topics: [TopicSegment], limit: Int) -> String {
        for cap in [6, 4, 3, 2, 1] {
            let text = render(topics, bulletCap: cap)
            if text.count <= limit { return text }
        }
        return String(render(topics, bulletCap: 1).prefix(limit))
    }

    static func render(_ topics: [TopicSegment], bulletCap: Int) -> String {
        topics.map { topic in
            ([topic.title] + topic.bullets.prefix(bulletCap).map { "- \($0)" })
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// Boş ve yinelenen maddeleri eler, madde başındaki listeleme işaretini atar.
    static func cleaned(_ bullets: [String]) -> [String] {
        var seen: Set<String> = []
        return bullets.compactMap { raw -> String? in
            let text = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix(while: { $0 == "-" || $0 == "•" || $0 == " " })
            let value = String(text)
            guard !value.isEmpty, seen.insert(normalized(value)).inserted else { return nil }
            return value
        }
    }

    /// Aynı başlık iki parçada da çıkabiliyor; ikincisinin maddeleri
    /// birincisine eklenir, bölüm tekrar etmez.
    static func deduplicatedTopics(_ topics: [TopicSegment]) -> [TopicSegment] {
        var order: [String] = []
        var byKey: [String: TopicSegment] = [:]
        for topic in topics {
            let key = normalized(topic.title)
            if let existing = byKey[key] {
                byKey[key] = TopicSegment(title: existing.title,
                                          bullets: cleaned(existing.bullets + topic.bullets),
                                          start: existing.start,
                                          end: max(existing.end, topic.end))
            } else {
                order.append(key)
                byKey[key] = topic
            }
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Toplantı sohbeti

    func answer(question: String, over segments: [Segment]) async throws -> String {
        guard availability.isAvailable else {
            throw OraError.modelUnavailable(reason: availability.turkishMessage)
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Bu toplantının transkripti yok")
        }

        let chunks = TranscriptChunker.chunks(of: segments,
                                              limit: TranscriptChunker.summaryLimit)

        // MAP — her parçaya soru ayrı sorulur; ilgisiz parçalar elenir.
        var findings: [String] = []
        for chunk in chunks {
            let session = LanguageModelSession(instructions: Self.instructions)
            let text = TranscriptChunker.render(chunk)
            do {
                let response = try await session.respond(to: """
                    Aşağıdaki toplantı bölümünde şu sorunun yanıtı var mı?
                    Soru: \(trimmed)

                    Varsa kısaca yaz. Yoksa yalnızca "YOK" yaz. Uydurma.

                    \(text)
                    """)
                let finding = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finding.isEmpty, !finding.uppercased(with: Locale(identifier: "tr_TR"))
                    .hasPrefix("YOK") {
                    findings.append(finding)
                }
            } catch {
                Log.warning(.intelligence, "Sohbet parçası atlandı: \(error.localizedDescription)")
            }
        }

        guard !findings.isEmpty else {
            return "Bu soruya toplantı transkriptinde bir yanıt bulamadım."
        }
        if findings.count == 1 { return findings[0] }

        // REDUCE — bulgular tek yanıta indirgenir.
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: """
                Soru: \(trimmed)

                Toplantının farklı bölümlerinden şu bulgular çıktı. Bunları
                birleştirerek soruyu Türkçe ve kısaca yanıtla. Bulgularda olmayan
                bir şey ekleme.

                \(findings.joined(separator: "\n---\n"))
                """)
            return response.content
        } catch {
            return findings.joined(separator: "\n\n")
        }
    }

    // MARK: - Otomatik başlık

    func generateTitle(from segments: [Segment]) async -> String? {
        await generateTitle(from: segments, topics: [])
    }

    /// Konu başlıkları varsa **onlardan** üretilir. Ölçüldü (RESEARCH.md §23.9):
    /// yalnızca ilk parçadan üretilen başlık toplantının tamamını temsil
    /// etmiyordu — 29 dakikalık bir bordro mutabakatı "Toplam Kazanç ve Diğer
    /// Kazançlar" oluyordu, çünkü ilk 6.000 karakter oradan geçiyordu.
    func generateTitle(from segments: [Segment],
                       topics: [TopicSegment]) async -> String? {
        guard availability.isAvailable, !segments.isEmpty else { return nil }

        let opening = TranscriptChunker.chunks(of: segments,
                                               limit: TranscriptChunker.summaryLimit).first ?? segments

        // Önce konu başlıklarından: ilk parça uzun bir toplantıyı temsil etmiyor.
        // Ama model başlık listesini **birleştirip** geri veriyor (ölçüldü,
        // RESEARCH.md §23.9) — sonuç geçersizse ilk parçaya düşülür.
        if topics.count > 1 {
            let kaynak = "Toplantının konu başlıkları:\n"
                + topics.map { "- \($0.title)" }.joined(separator: "\n")
            if let title = await title(from: kaynak), Self.isUsableTitle(title) {
                return title
            }
            Log.debug(.intelligence, "Konu başlıklarından üretilen başlık geçersiz, "
                      + "ilk parçaya düşülüyor")
        }
        return await title(from: TranscriptChunker.render(opening))
    }

    /// Model konu başlıklarını virgülle birleştirip geri verebiliyor.
    /// Başlık kısa olmalı ve liste gibi görünmemeli.
    static func isUsableTitle(_ title: String) -> Bool {
        title.split(separator: " ").count <= 7
            && title.filter { $0 == "," }.count <= 1
    }

    private func title(from source: String) async -> String? {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: """
                Bu toplantıya 3-6 kelimelik Türkçe bir başlık ver. Başlık
                toplantının **tamamını** temsil etmeli, tek bir bölümünü değil.
                Tarih yazma, tırnak kullanma, liste yapma, "toplantı" kelimesini
                gereksizce tekrarlama. "Ben", "Katılımcı" gibi konuşmacı
                etiketlerini başlığa koyma.

                \(source)
                """,
                generating: KonuBasligi.self)
            let title = response.content.baslik
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.\n"))
            return title.isEmpty ? nil : title
        } catch {
            Log.warning(.intelligence, "Başlık üretilemedi: \(error.localizedDescription)")
            return nil
        }
    }

    /// Model bazı karar ve aksiyonları iki kez üretebiliyor (ölçüldü,
    /// RESEARCH.md §15.2). Aynı içerik listede bir kez görünür.
    static func deduplicated(_ ozet: Ozet) -> Ozet {
        var seenOverview: Set<String> = []
        var seenDecisions: Set<String> = []
        var seenActions: Set<String> = []
        var result = ozet
        result.genelBakis = cleaned(ozet.genelBakis)
            .filter { seenOverview.insert(normalized($0)).inserted }
        result.kararlar = cleaned(ozet.kararlar)
            .filter { seenDecisions.insert(normalized($0)).inserted }
        // Aksiyonlar artık parça parça toplanıyor; aynı iş birden çok
        // parçada geçebiliyor ve toplam sayı şişebiliyor.
        result.aksiyonlar = ozet.aksiyonlar
            .filter { !$0.gorev.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { seenActions.insert(normalized($0.gorev)).inserted }
            .prefix(8)
            .map { $0 }
        return result
    }

    // MARK: - Doğrulama yardımcıları

    /// "3. Merhaba, nasılsın?" → "Merhaba, nasılsın?"
    static func numberedLines(_ response: String) -> [String] {
        response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let dot = trimmed.firstIndex(of: "."),
                      trimmed[trimmed.startIndex ..< dot].allSatisfy(\.isNumber),
                      dot < trimmed.endIndex
                else { return trimmed }
                return String(trimmed[trimmed.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Noktalama ve büyük/küçük harf dışındaki her fark reddedilir.
    static func sameWords(_ original: String, _ candidate: String) -> Bool {
        Self.normalized(original) == Self.normalized(candidate)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
