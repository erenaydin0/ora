import Foundation
import FoundationModels

/// Toplantı özeti — `@Generable` şema. Elle JSON ayrıştırma yazılmaz.
@Generable
struct Ozet: Sendable, Equatable {

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
        @Guide(description: "Yapılacak iş, emir kipiyle ve kısa. Yalnızca "
               + "henüz yapılmamış işler; tamamlanmış işler aksiyon değildir")
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
struct KonuBlogu: Sendable, Equatable {
    @Guide(description: "Bu konunun 2-6 kelimelik Türkçe başlığı")
    var baslik: String

    /// Tavan 8: az konu istendiğinde her konu daha ayrıntılı yazılmalı, yoksa
    /// uzun toplantının notu seyreliyor (referansta 66 dk → 6 bölüm / 42 madde).
    @Guide(description: "Bu konuda konuşulanlar. Her madde tek cümle ama iki "
           + "bölümlü olsun: önce ne olduğu, sonra sonucu ya da kimin ne "
           + "yapacağı", .maximumCount(8))
    var maddeler: [String]
}

/// Yalnızca başlık istenen yerler için (otomatik toplantı başlığı). Düz metin
/// istendiğinde model numaralı liste ve açıklama döküyor — şema şart
/// (RESEARCH.md §15.2).
@Generable
struct KonuBasligi: Sendable {
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
struct ParcaOzeti: Sendable, Equatable {
    @Guide(description: "Bu bölümde ele alınan ayrı konular", .maximumCount(4))
    var konular: [KonuBlogu]

    /// Tavan 3: gerçek bir toplantıda çoğu bölümde aksiyon **yoktur**
    /// (RESEARCH.md §23.9 — ekran paylaşımı anlatımında model 12 aksiyon
    /// uydurdu). Yüksek tavan modeli doldurmaya itiyor.
    @Guide(description: "Bu bölümde birinin açıkça üstlendiği işler. Çoğu "
           + "bölümde hiç yoktur; emin değilsen boş bırak", .maximumCount(3))
    var aksiyonlar: [Ozet.Aksiyon]
}

/// Birleştirme aşamasının çıktısı: yalnızca genel bakış ve kararlar.
/// Aksiyonlar `ParcaOzeti`'nden gelir.
@Generable
struct ToplantiOzeti: Sendable, Equatable {
    @Guide(description: "Toplantının en önemli sonuçları; her madde tek cümle",
           .maximumCount(6))
    var genelBakis: [String]

    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6))
    var kararlar: [String]
}

/// `topic_segments` tablosunun karşılığı.
struct TopicSegment: Sendable, Identifiable, Hashable {
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
struct SummaryContext: Sendable, Equatable {
    /// Göreli tarih ifadelerini ("Cuma", "haftaya") çözmek için.
    var meetingDate: Date
    /// Sorumlu kişi için kapalı liste. Takvim katılımcıları + kullanıcının adı.
    var participants: [String]
    /// Mikrofon kanalındaki kişi. Boşsa modele yalnızca "Ben" denir.
    var userName: String?

    static let empty = SummaryContext(meetingDate: .now, participants: [], userName: nil)
}
