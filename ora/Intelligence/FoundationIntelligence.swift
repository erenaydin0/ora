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
    /// **İstem İngilizce, çıktı Türkçe.** Ölçüldü (RESEARCH.md §24): aynı
    /// transkriptte üçer koşu — İngilizce istemle madde uzunluğu 60→70 karakter,
    /// çıkarılan karar 3,3→5,7, aksiyon 2,7→3,7, genel bakış/karar tekrarı
    /// 1,7→0,7. Süre aynı, guardrail ikisinde de 8/8. Model İngilizce ağırlıklı
    /// eğitilmiş; talimatı İngilizce vermek yönerge takibini artırıyor, çıktı
    /// dili ayrı bir cümleyle sabitleniyor.
    ///
    /// Kullanıcıya görünen hiçbir metin bundan etkilenmez.
    private static let instructions = """
        You are a meeting assistant. The meeting is in Turkish; write every
        output in Turkish.
        Use only information present in the text; do not infer or invent.
        Keep numbers, dates and proper nouns exactly as written.
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
                   variation: Bool = false,
                   progress: @Sendable @escaping (Double) -> Void) async throws
        -> SummaryResult {
        // Yeniden üretimde örnekleme serbestleşir; aynı istem aynı özeti
        // vermesin. Varsayılan geçiş dokunulmadan kalır.
        let options = Self.options(variation: variation)
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
                                             target: target, context: context,
                                             options: options),
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
            // Birleştirme ve son kontrol için pay bırakılır.
            progress(Double(index + 1) / Double(chunks.count) * 0.75)
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
                Below are topic-by-topic notes from a meeting. From them
                produce a 4-6 bullet overview of the meeting and the decisions
                that were made. Write everything in Turkish.
                Rules:
                - Each overview bullet is one sentence; first what happened,
                  then its consequence.
                - Do not write the meeting's date or duration in the overview.
                - Do not repeat the topic headings verbatim; write what happened.
                - Write as decisions only things that were actually decided.
                - The overview and the decisions must not be the same sentences.
                \(Self.dateLine(context))

                \(combined)
                """,
                generating: ToplantiOzeti.self,
                options: options)
            progress(0.85)
            let ozet = Ozet(genelBakis: response.content.genelBakis,
                            kararlar: response.content.kararlar,
                            aksiyonlar: aksiyonlar)
            // Son kontrol: üretilen cümlelerin dilbilgisi düzeltilir.
            // Başarısızlığa dayanıklı — düzeltilemeyen cümle olduğu gibi kalır.
            let (finalOzet, finalTopics) = await polished(
                Self.deduplicated(ozet), topics: topics) { value in
                    progress(0.85 + value * 0.15)
                }
            progress(1)
            return SummaryResult(ozet: finalOzet,
                                 topics: finalTopics,
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
                             context: SummaryContext,
                             options: GenerationOptions) async -> ParcaOzeti? {
        let prompt = """
            Split this meeting excerpt into its topics. Produce at most
            \(target) topics. For each topic write a 2-6 word Turkish heading
            and bullets describing what was discussed. If few topics are
            requested, write each one in more detail; give every important
            point its own bullet.
            Rules:
            - Each bullet is one sentence and must stand on its own.
            - Keep numbers, dates, company and person names exactly as in the text.
            - Do not write filler like "this was discussed"; write what happened.
            - Name whoever took something on. \(Self.selfLine(context))
            - Do not write speaker labels such as "Ben" or "Katılımcı" in a bullet.
            - Write each bullet as a note in the third person, describing what
              happened. Never write in the first person ("Ben", "yapacağım",
              "ediyorum").
            Action rules:
            - Only write work someone explicitly took on. Status statements
              ("this works", "this is finished") are not actions.
            - An excerpt may contain no actions at all; do not force any,
              leave the list empty.
            - Take the owner from whoever took the work on in the text; write
              "belirtilmedi" if it is unclear.
            - Write work still to be done, not work already finished.
            - In the context field write which part of the conversation the
              work came from.
            - Write a due date only if the text states one.
            \(Self.dateLine(context))

            \(text)
            """
        for attempt in 1 ... 2 {
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                return try await session.respond(to: prompt,
                                                 generating: ParcaOzeti.self,
                                                 options: options).content
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

    /// Yeniden üretimde örnekleme ayarı. Varsayılan geçişte hiçbir seçenek
    /// verilmez — ölçümler (RESEARCH.md §23-24) onunla alındı.
    static func options(variation: Bool) -> GenerationOptions {
        variation
            ? GenerationOptions(sampling: .random(probabilityThreshold: 0.95),
                                temperature: 0.9)
            : GenerationOptions()
    }

    /// Türkçe belirli geçmiş 3. tekil eki. Diakritikler `words(of:)` içinde
    /// zaten düşürüldüğü için sadeleşmiş biçimler yeterli.
    private static let pastEndings = ["di", "dı", "du", "dü", "ti", "tı", "tu", "tü"]

    static func validated(_ aksiyon: Ozet.Aksiyon, topicTitles: [String],
                          context: SummaryContext) -> Ozet.Aksiyon {
        var result = aksiyon
        result.kisi = resolvedPerson(aksiyon.kisi, context: context)
        // Konuşmacı etiketi görev ve bağlam alanlarına da sızıyor
        // ("Katılımcı, toplam kazancı analiz etti").
        result.gorev = withoutSpeakerPrefix(aksiyon.gorev)
        result.baglam = withoutSpeakerPrefix(aksiyon.baglam)

        // Bağlam **görevin kendisini** de tekrarlayabiliyor, yalnızca konu
        // başlığını değil: "…belirlemek." → "…hesaplanması konusu." Gerçek
        // veride en sık görülen tekrar buydu.
        // Kontroller **temizlenmiş** metin üzerinde yapılır; etiket sayılırsa
        // kelime sayısı yanlış çıkar.
        if result.baglam.split(separator: " ").count < 4
            || Self.isEcho(result.baglam, of: topicTitles + [result.gorev]) {
            result.baglam = ""
        }

        if Self.isMeetingDate(aksiyon.sonTarih, context.meetingDate) {
            result.sonTarih = "belirtilmedi"
        }
        return result
    }

    /// Bağlam, kendisine komşu bir metnin yeniden yazımı mı? Birebir eşleşme
    /// yetmiyor: model "Analiz Ekranı Durumu ve Yemek Parası Kalemi"
    /// başlığından "Analiz ekranı konusundan çıktı" üretiyor, görevden de
    /// "…belirlemek." → "…hesaplanması konusu." Ölçüt kelime örtüşmesi:
    /// bağlamın anlamlı kelimelerinin çoğu adaylardan birinde geçiyorsa
    /// bilgi taşımıyor demektir.
    static func isEcho(_ baglam: String, of candidates: [String]) -> Bool {
        let words = Set(words(of: baglam)).subtracting(fillerStems)
        guard !words.isEmpty else { return true }
        return candidates.contains { candidate in
            let other = Set(Self.words(of: candidate))
            guard !other.isEmpty else { return false }
            return Double(words.intersection(other).count) / Double(words.count) >= 0.6
        }
    }

    /// Tek başına bilgi taşımayan kelimeler. `words(of:)`'ten geçirilir ki
    /// gövdeleme ikisinde de aynı olsun.
    private static let fillerStems =
        Set(words(of: "konusundan konusunda çıktı çıkan hakkında ile için"))

    /// Son tarih toplantının kendi tarihi mi? Model tarihi "3 Eylül 2026" ya da
    /// "Perşembe, 3 Eylül 2026" biçiminde kopyalıyor — **içerme** aranır.
    static func isMeetingDate(_ value: String, _ date: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy"
        let stamp = normalized(formatter.string(from: date))
        return !stamp.isEmpty && normalized(value).contains(stamp)
    }

    /// Türkçe küçük harfe indirip harf/rakam dışını atarak kelimelere böler,
    /// sonra **gövdeye kırpar**.
    ///
    /// Kırpma şart: Türkçe eklemeli bir dil ve "kazançları" ile "kazançların"
    /// tam kelime olarak eşleşmiyor — gövdelemeden tekrar oranı 0,5'te kalıp
    /// eşiğin altında kalıyordu. İlk 5 harf, ek kuyruğunu atmaya yetiyor.
    static func words(of text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0.folding(options: .diacriticInsensitive,
                                     locale: Locale(identifier: "tr_TR"))) }
            .filter { $0.count > 2 }
            .map { String($0.prefix(5)) }
    }

    // MARK: - İstem parçaları

    /// Mikrofon kanalındaki kişi. Ad verilmemişse yalnızca "Ben" denir —
    /// bu cümle olmadan `kisi` alanı hep "belirtilmedi" geliyor (RESEARCH.md §15.2).
    static func selfLine(_ context: SummaryContext) -> String {
        guard let name = context.userName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return "\"Ben\" is the person recording." }
        return "\"Ben\" is the person recording, named \(name)."
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
        return "Meeting date: \(formatter.string(from: context.meetingDate)). "
            + "Interpret weekday names in the text relative to this date; "
            + "do not invent dates."
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
            let value = withoutSpeakerPrefix(String(text))
            guard !value.isEmpty, seen.insert(normalized(value)).inserted else { return nil }
            return value
        }
    }

    /// "Ben: Kayıt paylaşımını kontrol ediyorum." → "Kayıt paylaşımını kontrol
    /// ediyorum." Virgüllü biçim de aynı: "Katılımcı, kontrol ediyor." →
    /// "Kontrol ediyor."
    ///
    /// İstem konuşmacı etiketini maddeye yazmamayı söylüyor ama model dinlemiyor
    /// — §23.6'daki desen: "şunu yazma" 3B modelde tutmuyor, kodda kesilmeli.
    /// Model etiketi hem `:` ile önek hem de `,` ile **özne** olarak kullanıyor;
    /// ikincisi üstelik bozuk cümle kuruyor ("Ben, … kontrol ediyor").
    ///
    /// Yalnızca **bilinen etiketler** atılır; "Karar: …" gibi meşru bir önek
    /// hayatta kalsın diye ayraç öncesi körlemesine silinmez. "Katılımcılar"
    /// gibi gerçek bir özne de etkilenmez — tam eşleşme aranır.
    static func withoutSpeakerPrefix(_ text: String) -> String {
        let labels = Channel.allCases.map { normalized($0.speaker) }
            + [normalized("belirtilmedi")]
        // Ayraçlı biçim: "Ben: …" / "Katılımcı, …"
        var rest: String
        if let separator = text.firstIndex(where: { $0 == ":" || $0 == "," }),
           case let head = String(text[text.startIndex ..< separator]),
           head.count <= 15, labels.contains(normalized(head)) {
            rest = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        } else if let space = text.firstIndex(of: " "),
                  labels.contains(normalized(String(text[text.startIndex ..< space]))) {
            // Ayraçsız biçim: "Ben kazançların toplamı üzerinde çalışıyor."
            rest = String(text[text.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            return text
        }
        guard let first = rest.first else { return rest }
        return String(first).uppercased(with: Locale(identifier: "tr_TR"))
            + rest.dropFirst()
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

    // MARK: - Son kontrol (dilbilgisi)

    /// Üretilen cümleleri dilbilgisi açısından düzeltir.
    ///
    /// Model Türkçe'de sık sık hâl eki tutturamıyor ("Analiz akışını uçtan uca
    /// çalıştırıldı" — belirtme hâli + edilgen çatı). Bu adım cümleleri
    /// düzeltir ama **bilgi eklemez/çıkarmaz**: numaralı satır protokolü
    /// noktalama adımından devralındı (satır sayısı tutmazsa parça bütünüyle
    /// reddedilir) ve satır başına olgu koruma güvencesi eklendi.
    ///
    /// Başarısızlık zararsızdır: düzeltilemeyen satır olduğu gibi kalır.
    func polished(_ ozet: Ozet, topics: [TopicSegment],
                  progress: @Sendable @escaping (Double) -> Void) async
        -> (Ozet, [TopicSegment]) {
        guard availability.isAvailable else { return (ozet, topics) }

        // Tüm cümleler tek sıraya dizilir, düzeltilir, sıra korunarak geri yazılır.
        var lines: [String] = ozet.genelBakis + ozet.kararlar
        for action in ozet.aksiyonlar { lines.append(action.gorev); lines.append(action.baglam) }
        for topic in topics { lines.append(contentsOf: topic.bullets) }
        guard !lines.isEmpty else { return (ozet, topics) }

        var fixed: [String] = []
        let chunks = Self.batches(of: lines, limit: TranscriptChunker.punctuationLimit)
        for (index, chunk) in chunks.enumerated() {
            fixed.append(contentsOf: await polish(chunk))
            progress(Double(index + 1) / Double(chunks.count))
        }
        guard fixed.count == lines.count else { return (ozet, topics) }

        var cursor = 0
        func next(_ count: Int) -> [String] {
            defer { cursor += count }
            return Array(fixed[cursor ..< cursor + count])
        }

        var result = ozet
        result.genelBakis = next(ozet.genelBakis.count)
        result.kararlar = next(ozet.kararlar.count)
        result.aksiyonlar = ozet.aksiyonlar.map { action in
            var copy = action
            copy.gorev = next(1)[0]
            copy.baglam = next(1)[0]
            return copy
        }
        let newTopics = topics.map { topic in
            TopicSegment(title: topic.title, bullets: next(topic.bullets.count),
                         start: topic.start, end: topic.end)
        }
        return (result, newTopics)
    }

    /// Bir grup satırı düzeltir. Sözleşme noktalama adımıyla aynı: numaralı
    /// gir, numaralı çık, satır sayısı değişirse parçayı komple reddet.
    private func polish(_ lines: [String]) async -> [String] {
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let prompt = """
            Fix the grammar of the following numbered Turkish sentences.
            Rules:
            - Keep the meaning. Do not add or remove information.
            - Keep every number, date and proper noun exactly as written.
            - Keep the line count and the numbering exactly as given.
            - An empty line stays empty.
            - Return only the lines, no commentary.

            \(numbered)
            """
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let content = try await session.respond(to: prompt).content
            let candidates = Self.numberedLines(content)
            guard candidates.count == lines.count else {
                Log.warning(.intelligence, "Dilbilgisi parçası atlandı: satır sayısı "
                            + "uyuşmadı (\(candidates.count) ≠ \(lines.count))")
                return lines
            }
            return zip(lines, candidates).map { original, candidate in
                Self.keepsFacts(original, candidate) ? candidate : original
            }
        } catch {
            Log.warning(.intelligence, "Dilbilgisi parçası başarısız: "
                        + "\(error.localizedDescription)")
            return lines
        }
    }

    /// Düzeltme, cümledeki **olguları** koruyor mu?
    ///
    /// Noktalama adımındaki "kelimeler aynı kalmalı" güvencesi burada
    /// kullanılamaz — dilbilgisi düzeltmesi zaten kelime değiştirir. Bunun
    /// yerine değişmemesi gerekenler korunur: sayılar ve cümle başında
    /// olmayan büyük harfli kelimeler (özel isimler). Ayrıca uzunluk yarıdan
    /// aza inmiş ya da iki katına çıkmışsa düzeltme değil yeniden yazımdır.
    static func keepsFacts(_ original: String, _ candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty
                || original.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        guard ratio > 0.5, ratio < 2 else { return false }

        let haystack = normalized(candidate)
        return facts(in: original).allSatisfy { haystack.contains($0) }
    }

    /// Sayılar ve cümle başında olmayan büyük harfli kelimeler.
    static func facts(in text: String) -> [String] {
        let tokens = text.split { !$0.isLetter && !$0.isNumber && $0 != "%" }
        return tokens.enumerated().compactMap { index, raw -> String? in
            let token = String(raw)
            if token.contains(where: \.isNumber) { return normalized(token) }
            // Cümle başı büyük harfi özel isim değildir.
            guard index > 0, let first = token.first, first.isUppercase,
                  token.count > 2 else { return nil }
            return normalized(token)
        }
        .filter { !$0.isEmpty }
    }

    /// Satırları toplam karakter sınırına göre gruplar.
    static func batches(of lines: [String], limit: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if !current.isEmpty, size + line.count + 5 > limit {
                result.append(current); current = []; size = 0
            }
            current.append(line)
            size += line.count + 5
        }
        if !current.isEmpty { result.append(current) }
        return result
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
                    Does the following meeting excerpt answer this question?
                    Question: \(trimmed)

                    If it does, answer briefly in Turkish. If it does not,
                    write only "YOK". Do not invent anything.

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
                Question: \(trimmed)

                These findings came from different parts of the meeting. Combine
                them and answer the question briefly, in Turkish. Do not add
                anything that is not in the findings.

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
                Give this meeting a 3-6 word title in Turkish. The title must
                represent the **whole** meeting, not one section of it.
                No date, no quotation marks, no list, do not repeat the word
                "toplantı" needlessly. Do not put speaker labels such as "Ben"
                or "Katılımcı" in the title.

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
        // Karar, genel bakışın kopyası olmamalı. İstemde kural var ama model
        // yine de aynı cümleyi iki alana yazabiliyor (ölçüldü, RESEARCH.md §24);
        // aynı cümle iki başlık altında iki kez okunmaz.
        let overview = Set(result.genelBakis.map(normalized))
        result.kararlar = cleaned(ozet.kararlar)
            .filter { !overview.contains(normalized($0)) }
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
