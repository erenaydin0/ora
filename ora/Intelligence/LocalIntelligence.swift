import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// İsteğe bağlı ikinci özetleme motoru: cihazda koşan, indirilen bir model.
///
/// **Yalnızca özetlemeyi devralır.** Noktalama, başlık üretimi ve toplantı
/// sohbeti Apple'ın modelinde kalır (`fallback`) — üçü de ölçülmüş, ucuz ve
/// yeterli. Devralınan tek şey ölçülen zayıf halka: özet (RESEARCH.md §35).
///
/// **Map-reduce yok.** Kazancın büyük kısmı modelden değil yapıdan geliyor:
/// 256K bağlam sayesinde toplantının tamamı tek isteme sığıyor ve model ilk
/// kez bütünü aynı anda görüyor. Ölçüldü (§37): tek sunuculu toplantıda
/// kapsama %13 → %44.
///
/// **İstem Türkçe.** CLAUDE.md'nin "istemler İngilizce yazılır" kuralı Apple'ın
/// modelinde ölçüldü (§24.2); buradaki %38 Türkçe istemle alındı ve bu modelde
/// İngilizce denenmedi. Kural motoruna göre değişir, ölçüm olmadan taşınmaz.
nonisolated struct LocalIntelligence: Intelligent {

    let model: LocalModel
    /// Devralınmayan işler buraya gider.
    let fallback: any Intelligent

    init(model: LocalModel = .qwen35_9B, fallback: any Intelligent = FoundationIntelligence()) {
        self.model = model
        self.fallback = fallback
    }

    /// Üretilecek en fazla token. Ölçümde 2.724-4.068 arası kullanıldı (§37);
    /// tavan cömert bırakıldı, yarım kalan JSON hiç çıktı vermemek demek.
    private static let maxTokens = 6_000

    var availability: ModelAvailability {
        guard LocalModelStore.isInstalled(model) else { return .localModelMissing }
        return .available
    }

    // MARK: - Devralınan tek iş

    @concurrent func summarize(_ segments: [Segment], context: SummaryContext,
                               variation: Bool,
                               progress: @Sendable @escaping (Double) -> Void) async throws
        -> SummaryResult {

        guard LocalModelStore.isInstalled(model) else {
            throw OraError.modelUnavailable(reason: ModelAvailability.localModelMissing.turkishMessage)
        }
        guard !segments.isEmpty else {
            throw OraError.modelUnavailable(reason: "Özetlenecek metin yok")
        }

        let session = try await Self.session(model: model, progress: { value in
            // Yükleme ilerlemesi ilk %20'ye sıkıştırılır; asıl iş üretim.
            progress(value * 0.2)
        })

        let body = TranscriptChunker.render(segments)
        Log.info(.intelligence, "Yerel motor: \(model.id), \(body.count) karakter tek geçişte")

        var output = ""
        var tokens = 0
        for try await chunk in session.streamResponse(to: Self.prompt(body: body,
                                                                     context: context)) {
            output += chunk
            tokens += 1
            // Üretim uzunluğu önceden bilinmiyor; ölçülen tipik uzunluğa
            // (~3.000 token) göre kabaca ilerletilir ve %95'te durdurulur —
            // geriye giden bir çubuk, duran bir çubuktan kötüdür.
            progress(0.2 + min(0.75, Double(tokens) / 3_000 * 0.75))
        }
        progress(0.95)

        guard let payload = Self.json(in: output) else {
            Log.warning(.intelligence, "Yerel motor JSON döndürmedi (\(output.count) karakter)")
            throw OraError.modelUnavailable(reason: "Model beklenen biçimde yanıt vermedi")
        }

        let speakers = Set(segments.map(\.speaker))
        let index = TranscriptIndex(segments)
        let topics = payload.topics.compactMap { topic -> TopicSegment? in
            let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let bullets = FoundationIntelligence.cleaned(topic.bullets, speakers: speakers)
            guard !title.isEmpty, !bullets.isEmpty else { return nil }
            // Tek geçişte konunun zamanı yok; alıntı bağı (§25.2) ile
            // transkriptteki yerine demirlenir, yoksa "konudan transkripte
            // atla" özelliği sessizce ölürdü.
            let anchor = bullets.compactMap { index.match($0)?.start }.min()
                ?? segments.first?.start ?? 0
            return TopicSegment(title: title, bullets: bullets,
                                start: anchor, end: segments.last?.end ?? anchor)
        }
        guard !topics.isEmpty else {
            throw OraError.modelUnavailable(reason: "Toplantı özetlenemedi")
        }

        let ozet = Ozet(
            genelBakis: FoundationIntelligence.cleaned(payload.overview, speakers: speakers),
            kararlar: FoundationIntelligence.cleaned(payload.decisions, speakers: speakers),
            aksiyonlar: FoundationIntelligence.ranked(payload.actions.compactMap { raw in
                let gorev = raw.gorev.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !gorev.isEmpty, !FoundationIntelligence.isStatusNotTask(gorev) else {
                    return nil
                }
                return FoundationIntelligence.validated(
                    Ozet.Aksiyon(kisi: raw.kisi, gorev: gorev, baglam: raw.baglam,
                                 sonTarih: raw.sonTarih.isEmpty ? "belirtilmedi" : raw.sonTarih),
                    topicTitles: topics.map(\.title), context: context)
            }))
        progress(1)
        Log.info(.intelligence, "Yerel motor bitti — \(topics.count) konu, "
                 + "\(ozet.aksiyonlar.count) aksiyon")
        return SummaryResult(ozet: FoundationIntelligence.deduplicated(ozet),
                             topics: FoundationIntelligence.deduplicatedTopics(topics),
                             skippedChunks: 0)
    }

    // MARK: - Devredilenler

    @concurrent func restorePunctuation(_ segments: [Segment],
                                        progress: @Sendable @escaping (Double) -> Void) async throws
        -> [Segment] {
        try await fallback.restorePunctuation(segments, progress: progress)
    }

    @concurrent func answer(question: String, over segments: [Segment]) async throws -> String {
        try await fallback.answer(question: question, over: segments)
    }

    @concurrent func generateTitle(from segments: [Segment]) async -> String? {
        await fallback.generateTitle(from: segments)
    }

    @concurrent func generateTitle(from segments: [Segment],
                                   topics: [TopicSegment]) async -> String? {
        await fallback.generateTitle(from: segments, topics: topics)
    }

    // MARK: - Model

    /// Modeli yükler ve bir oturum açar.
    ///
    /// **Oturum saklanmaz.** 7 GB'lık bir modeli arka planda bellekte tutmak,
    /// toplantı kaydeden bir uygulamada kabul edilemez; her özetlemede yüklenir
    /// ve iş bitince bırakılır. Ölçüldü (§37): yükleme 1,3-2,9 sn, özetlemenin
    /// yanında ihmal edilebilir.
    static func session(model: LocalModel,
                        progress: @Sendable @escaping (Double) -> Void) async throws -> ChatSession {
        let container = try await loadModelContainer(
            from: #hubDownloader(HubClient(host: hubHost,
                                           cache: HubCache(cacheDirectory: LocalModelStore.directory))),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.id)
        ) { value in progress(value.fractionCompleted) }

        var parameters = GenerateParameters()
        // Örnekleme kapalı: §37 ölçümleri `temp=0` ile alındı.
        parameters.temperature = 0
        parameters.maxTokens = maxTokens
        return ChatSession(container, instructions: instructions,
                           generateParameters: parameters)
    }

    static let hubHost = URL(string: "https://huggingface.co")!

    /// Modeli **indirir**; kurulumu Ayarlar'dan kullanıcı başlatır.
    /// Yükleme ile aynı yol: indirici aynı önbelleğe yazar, sonraki
    /// özetlemede ağa hiç çıkılmaz.
    static func download(_ model: LocalModel,
                         progress: @Sendable @escaping (Double) -> Void) async throws {
        _ = try await session(model: model, progress: progress)
        Log.info(.intelligence, "Yerel model indirildi: \(model.id) "
                 + "(\(AudioArchive.sizeLabel(LocalModelStore.bytes(model))))")
    }

    // MARK: - İstem

    private static let instructions = """
        Sen bir toplantı asistanısın. Toplantı Türkçe; her çıktıyı Türkçe yaz. \
        Yalnızca metinde geçen bilgiyi kullan, çıkarım yapma, uydurma. Sayıları, \
        tarihleri ve özel isimleri metindeki gibi koru.

        Toplantı notu bilgi yazar, kimin konuştuğunu değil. Not okuyucuya bir \
        şeyin ne olduğunu, neye karar verildiğini, bir sayının ne olduğunu ya da \
        ne yapılacağını öğretir. "Ayşe, ödeme akışını açıkladı" bir not değildir; \
        "Ödeme akışı üç adımdan oluşuyor" nottur.
        """

    /// §37'de ölçülen istem. Yoğunluk satırları (8-12 konu, sayıları maddeye
    /// taşı) kapsamayı %32'den %38'e çıkardı; bedeli kuyrukta zayıf konu
    /// başlıkları. İki satırdan biri değiştirilecekse önce `probes` tezgâhı
    /// yeniden koşturulur.
    static func prompt(body: String, context: SummaryContext) -> String {
        """
        Aşağıda bir toplantının tam dökümü var. Toplantı notunu çıkar.

        Kurallar:
        - Genel bakış 4-6 madde: toplantının en önemli sonuçları, sayılarıyla.
        - Konu başlıkları toplantının gerçek konularını izlesin (8-12 konu), her
          konunun altında 4-6 madde olsun. Not seyrek olmasın.
        - Dökümde geçen sayı, tutar, oran, yüzde, tarih, süre, ürün ve firma
          adlarını maddelerin içine taşı; genel bir cümleyle geçiştirme.
        - Madde konuşmayı değil olguyu anlatır; konuşma fiiliyle bitmez.
        - Aksiyon, toplantıdan sonra yapılacak iştir. Toplantı sırasında
          gösterilen, anlatılan ya da tamamlanan bir şey aksiyon değildir.
          Sahibini metindeki addan al; belli değilse "belirtilmedi" yaz.
        - Karar, grubun üzerinde anlaştığı şeydir; konu başlığı karar değildir.
        \(FoundationIntelligence.dateLine(context))

        Yalnızca şu şemada JSON döndür, başka hiçbir şey yazma:
        {
          "overview": ["genel bakış maddesi"],
          "decisions": ["alınan karar"],
          "actions": [{"kisi": "ad ya da belirtilmedi", "gorev": "emir kipiyle iş",
                       "baglam": "işin hangi konuşmadan çıktığı",
                       "sonTarih": "tarih ya da belirtilmedi"}],
          "topics": [{"title": "2-6 kelimelik başlık", "bullets": ["madde"]}]
        }

        TOPLANTI DÖKÜMÜ:
        \(body)
        """
    }

    // MARK: - Çıktıyı çözme

    struct Payload: Decodable {
        struct Action: Decodable {
            var kisi = "belirtilmedi"
            var gorev = ""
            var baglam = ""
            var sonTarih = "belirtilmedi"
        }
        struct Topic: Decodable {
            var title = ""
            var bullets: [String] = []
        }
        var overview: [String] = []
        var decisions: [String] = []
        var actions: [Action] = []
        var topics: [Topic] = []
    }

    /// Model JSON'u düz metne sarabiliyor ("İşte notlar: {…}"); en dıştaki
    /// süslü parantez çifti alınır. Şema zorlaması olmayan bir modelde bu
    /// ayrıştırma **şart**, `@Generable` karşılığı yok.
    static func json(in text: String) -> Payload? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let slice = String(text[start ... index])
                    return try? JSONDecoder().decode(Payload.self, from: Data(slice.utf8))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
