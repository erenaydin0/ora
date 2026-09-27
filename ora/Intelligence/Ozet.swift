import Foundation
import FoundationModels

/// Toplantı özeti — `@Generable` şema. Elle JSON ayrıştırma yazılmaz.
@Generable
nonisolated struct Ozet: Sendable, Equatable {

    /// Paragraf değil **madde listesi**. Ölçüldü (`circleback-notes/`): iyi bir
    /// toplantı notu her zaman 4-6 maddelik bir genel bakışla açılıyor; tek
    /// paragraf hem taranamıyor hem de modeli özetin özetini yazmaya itiyor.
    @Guide(description: "Toplantının en önemli sonuçları; her madde tek cümle",
           .maximumCount(6))
    var genelBakis: [String]

    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6))
    var kararlar: [String]

    @Generable
    struct Aksiyon: Sendable, Equatable, Identifiable {
        @Guide(description: "Sorumlu kişinin adı, belli değilse 'belirtilmedi'")
        var kisi: String
        @Guide(description: "Yapılacak iş, emir kipiyle ve kısa: cümle işle "
               + "başlar, fiille biter. Yalnızca toplantıdan sonra yapılacak "
               + "işler; toplantıda anlatılan, gösterilen ya da tamamlanmış "
               + "bir şey aksiyon değildir")
        var gorev: String
        /// Görevin kendisi değil, **neden çıktığı**. Referans çıktılarda her
        /// aksiyonun altında bir cümlelik gerekçe var ("Çağrı'nın talebi: …")
        /// ve maddeyi tek başına anlaşılır kılan şey bu.
        /// Tam cümle istenir: "yoksa boş" denildiğinde model tek kelimelik
        /// bir kişi adı yazıyordu, "neden" denildiğinde ise "gereklidir" gibi
        /// klişe kuruyordu (ölçüm: RESEARCH.md §23).
        @Guide(description: "Bu işin hangi konuşmadan çıktığını anlatan tam bir cümle")
        var baglam: String
        /// **Şemadan çıkarma.** Önceki ora'da bu alan istenmediği için DB'deki
        /// `deadline` sütunu hep NULL kalıyordu.
        @Guide(description: "Son tarih, belirtilmemişse 'belirtilmedi'")
        var sonTarih: String

        var id: String { "\(kisi)-\(gorev)" }
    }

    @Guide(description: "Aksiyon maddeleri", .maximumCount(8))
    var aksiyonlar: [Aksiyon]
}

/// Bir konu bloğu: başlık **ve gövde**. Önceden yalnızca başlık isteniyordu;
/// gövde aynı döngüde üretilip birleştirme adımında kaybediliyordu.
@Generable
nonisolated struct KonuBlogu: Sendable, Equatable {
    @Guide(description: "Bu konunun 2-6 kelimelik Türkçe başlığı")
    var baslik: String

    /// Tavan 8: az konu istendiğinde her konu daha ayrıntılı yazılmalı, yoksa
    /// uzun toplantının notu seyreliyor (referansta 66 dk → 6 bölüm / 42 madde).
    /// **"Konuşulanlar" demek anlatım üretiyor** (ölçüldü, RESEARCH.md §33):
    /// maddelerin %40'ı "X, Y'yi açıkladı" kalıbındaydı. Kılavuz metni
    /// üretimin en yakınındaki yönergedir; bilgi istenmeli, konuşma değil.
    @Guide(description: "Bu konudan çıkan bilgiler: kararlar, sayılar, bir "
           + "şeyin nasıl çalıştığı, sorunlar, kimin ne yapacağı. Kimin "
           + "konuştuğu değil, ne olduğu yazılır. Her madde tek cümle",
           .maximumCount(8))
    var maddeler: [String]
}

/// Yalnızca başlık istenen yerler için (otomatik toplantı başlığı). Düz metin
/// istendiğinde model numaralı liste ve açıklama döküyor — şema şart
/// (RESEARCH.md §15.2).
@Generable
nonisolated struct KonuBasligi: Sendable {
    @Guide(description: "2-6 kelimelik Türkçe başlık")
    var baslik: String
}

/// Bir parçadan çıkan konular **ve aksiyonlar**. Parça sınırı bağlam
/// penceresinden geliyor, konu sınırı konuşmadan — bu yüzden bir parça birden
/// çok konu içerebilir. Zaman aralığı LLM'e sorulmaz; parçanın
/// segmentlerinden bilinir.
///
/// **Aksiyonlar neden burada:** ölçüldü (RESEARCH.md §23) — aksiyonlar
/// birleştirme aşamasında konu notlarından çıkarıldığında sorumlu kişi
/// yanlış atanıyordu; notlarda konuşmacı bilgisi yok, model de kapalı isim
/// listesini bir menü gibi kullanıyordu. Parça metninde konuşma sırası ve
/// adlar duruyor; aksiyon oradan çıkarılmalı.
@Generable
nonisolated struct ParcaOzeti: Sendable, Equatable {
    @Guide(description: "Bu bölümde ele alınan ayrı konular", .maximumCount(4))
    var konular: [KonuBlogu]

    /// Tavan 3: gerçek bir toplantıda çoğu bölümde aksiyon **yoktur**
    /// (RESEARCH.md §23.9 — ekran paylaşımı anlatımında model 12 aksiyon
    /// uydurdu). Yüksek tavan modeli doldurmaya itiyor.
    @Guide(description: "Bu bölümde birinin açıkça üstlendiği işler. Çoğu "
           + "bölümde hiç yoktur; emin değilsen boş bırak", .maximumCount(3))
    var aksiyonlar: [Ozet.Aksiyon]
}

/// Kullanıcının notuna transkriptten eklenen ayrıntı (COMPETITION.md §4.6).
/// Not kullanıcınındır; model yalnızca **altına** madde ekler.
@Generable
nonisolated struct NotAyrintisi: Sendable, Equatable {
    @Guide(description: "Notu genişleten somut ayrıntılar: sayılar, adlar, kararlar, "
           + "kimin ne yapacağı. Her madde tek cümle. Metinde yoksa boş bırak",
           .maximumCount(3))
    var maddeler: [String]
}

/// Birleştirme aşamasının çıktısı: yalnızca genel bakış ve kararlar.
/// Aksiyonlar `ParcaOzeti`'nden gelir.
@Generable
nonisolated struct ToplantiOzeti: Sendable, Equatable {
    @Guide(description: "Toplantının en önemli sonuçları; her madde tek cümle "
           + "ve mümkünse sayı, ad ya da sonuç taşısın", .maximumCount(6))
    var genelBakis: [String]

    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6))
    var kararlar: [String]
}

/// `topic_segments` tablosunun karşılığı.
nonisolated struct TopicSegment: Sendable, Identifiable, Hashable {
    let title: String
    let bullets: [String]
    let start: TimeInterval
    let end: TimeInterval
    var id: String { "\(start)-\(title)" }

    init(title: String, bullets: [String] = [],
         start: TimeInterval, end: TimeInterval) {
        self.title = title
        self.bullets = bullets
        self.start = start
        self.end = end
    }

    /// Bir saati aşan toplantıda `MM:SS` yanlış okunuyordu (90 dakika "90:12").
    var timeLabel: String {
        let total = Int(start)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Özetleme istemini besleyen toplantı bağlamı.
///
/// İkisi de **isteğe bağlı**: takvim kapalıysa `participants` boştur ve isteme
/// hiç satır yazılmaz — boş bir liste vermek `kisi` alanını bozuyor.
nonisolated struct SummaryContext: Sendable, Equatable {
    /// Göreli tarih ifadelerini ("Cuma", "haftaya") çözmek için.
    var meetingDate: Date
    /// Sorumlu kişi için kapalı liste. Takvim katılımcıları + kullanıcının adı.
    var participants: [String]
    /// Mikrofon kanalındaki kişi. Boşsa modele yalnızca "Ben" denir.
    var userName: String?
    /// Transkriptin satırları **gerçek adlarla** mı başlıyor (içe aktarılan
    /// döküm) yoksa kanal etiketleriyle mi ("Ben" / "Katılımcı", kendi
    /// kaydımız)? İstem buna göre değişir — bkz. `speakerLine`.
    var hasNamedSpeakers = false
    /// Adlandırılmış satırların yanında "Ben" satırları da var mı? Ses izinden
    /// kişi tanınan kendi kaydımızda olur; o zaman "Ben"in kim olduğu yine
    /// söylenmeli. İçe aktarılan tamamen adlı dökümde yanlıştır (§33).
    var hasRecorderLines = false
    /// Kullanıcının seçtiği özet uzunluğu (Ayarlar → Özetleme).
    var detail: SummaryDetail = .balanced
    /// Kullanıcının notları ve işaretlediği anlar. Boşken istem ölçülen
    /// metinle bayt bayt aynıdır.
    var notebook = NotebookHints()
    /// Toplantı şablonu. Genel'de istem ölçülen metinle bayt bayt aynıdır.
    var template: MeetingTemplate = .general

    static let empty = SummaryContext(meetingDate: .now, participants: [], userName: nil)
}

/// Özet uzunluğu.
///
/// **Dengeli ölçülmüş olandır** (RESEARCH.md §23-37): o seviyede istem metni
/// ve sınırlar eskisiyle **bayt bayt aynıdır** — `SummaryShapeTests` bunu
/// denetler. Kısa ve Ayrıntılı ölçülmedi; kapsama puanıyla (§35)
/// değerlendirilmeden varsayılan yapılmaz.
///
/// **Aksiyonlar her uzunlukta aynıdır.** Kullanıcının nota ilk sorusu "bana ne
/// düştü" (özet sırası buna göre kuruldu); kısa not, aksiyonu kısaltarak
/// kısalmaz.
nonisolated enum SummaryDetail: String, CaseIterable, Sendable, Identifiable {
    case brief
    case balanced
    case detailed

    var id: String { rawValue }

    var turkishName: String {
        switch self {
        case .brief:    "Kısa"
        case .balanced: "Dengeli"
        case .detailed: "Ayrıntılı"
        }
    }

    var turkishDetail: String {
        switch self {
        case .brief:
            "Az konu, konu başına en fazla üç madde. Hızlı göz atmak için."
        case .balanced:
            "Ölçülmüş varsayılan."
        case .detailed:
            "Daha çok konu ve madde. Uzun toplantıda not seyrelmesin diye."
        }
    }

    // MARK: Apple motoru (map-reduce)

    /// Toplantı başına hedef konu sayısı; parça sayısına bölünür
    /// (`FoundationIntelligence.topicTarget`). Dengeli'deki 6 ölçülmüş değerdir.
    var topicBudget: Double {
        switch self {
        case .brief:    3
        case .balanced: 6
        case .detailed: 10
        }
    }

    /// Birleştirme istemindeki genel bakış aralığı.
    var overviewRange: String {
        switch self {
        case .brief:    "2-3"
        case .balanced: "4-6"
        case .detailed: "5-6"
        }
    }

    /// Parça istemine eklenen cümle. Dengeli'de **boş** — istem değişmez.
    var chunkHint: String {
        switch self {
        case .brief:
            " Keep only the most important points: at most 3 bullets per "
                + "topic, preferring those that carry numbers and decisions."
        case .balanced:
            ""
        case .detailed:
            " Be thorough: give every concrete fact, number and decision its "
                + "own bullet."
        }
    }

    // MARK: Yerel motor (tek geçiş)

    var localOverview: String {
        switch self {
        case .brief:    "3"
        case .balanced: "4-6"
        case .detailed: "5-6"
        }
    }

    var localTopics: String {
        switch self {
        case .brief:    "4-6"
        case .balanced: "8-12"
        case .detailed: "10-14"
        }
    }

    var localBullets: String {
        switch self {
        case .brief:    "2-3"
        case .balanced: "4-6"
        case .detailed: "5-8"
        }
    }

    var localDensity: String {
        self == .brief ? "Yalnızca en önemli bilgiyi yaz." : "Not seyrek olmasın."
    }

    // MARK: Kesin sınır

    /// Konu başına en fazla madde. Nil: şemanın tavanı.
    var bulletCap: Int? { self == .brief ? 3 : nil }
    /// Genel bakışta en fazla madde. Nil: şemanın tavanı.
    var overviewCap: Int? { self == .brief ? 3 : nil }

    /// İstem sınırı ölçümde tutmadı (§23: "en fazla N konu" dendi, 23 bölüm
    /// çıktı); Kısa'nın vaadi kodda uygulanır. Aksiyonlara dokunulmaz.
    func shaped(_ result: SummaryResult) -> SummaryResult {
        guard bulletCap != nil || overviewCap != nil else { return result }
        var ozet = result.ozet
        if let overviewCap { ozet.genelBakis = Array(ozet.genelBakis.prefix(overviewCap)) }
        let topics = result.topics.map { topic in
            guard let bulletCap else { return topic }
            return TopicSegment(title: topic.title,
                                bullets: Array(topic.bullets.prefix(bulletCap)),
                                start: topic.start, end: topic.end)
        }
        return SummaryResult(ozet: ozet, topics: topics, skippedChunks: result.skippedChunks)
    }
}
