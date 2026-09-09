import Foundation
import FoundationModels

/// Apple Intelligence'ın bu makinedeki durumu.
nonisolated enum ModelAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// İsteğe bağlı yerel model seçili ama indirilmemiş (ya da yarım inmiş).
    case localModelMissing

    var isAvailable: Bool { self == .available }

    var turkishMessage: String {
        switch self {
        case .available:                  ""
        case .deviceNotEligible:          "Bu Mac Apple Intelligence'ı desteklemiyor"
        case .appleIntelligenceNotEnabled: "Apple Intelligence kapalı"
        case .modelNotReady:              "Apple Intelligence modeli henüz hazır değil"
        case .localModelMissing:          "Seçili özetleme modeli indirilmemiş"
        }
    }

    var turkishDetail: String {
        switch self {
        case .available:
            ""
        case .deviceNotEligible:
            "Transkript oluşturulmaya devam eder; yalnızca özet ve noktalama devre dışı kalır."
        case .appleIntelligenceNotEnabled:
            "Sistem Ayarları → Apple Intelligence ve Siri bölümünden açabilirsiniz. "
            + "Kapalıyken transkript yine oluşturulur, yalnızca özet devre dışı kalır."
        case .modelNotReady:
            "Model indiriliyor veya hazırlanıyor. Birkaç dakika sonra tekrar deneyin; "
            + "bu sırada transkript oluşturulmaya devam eder."
        case .localModelMissing:
            "Ayarlar → Özetleme bölümünden modeli indirin ya da Apple modeline dönün. "
            + "Transkript her hâlükârda oluşturulur."
        }
    }
}

/// Özetleme aşamalarının ilerlemesi.
nonisolated enum IntelligenceStage: Sendable, Equatable {
    case punctuating(Double)
    case summarizing(Double)
}

/// Özetleme sonucu. Atlanan parça sayısı da döner — bir bölüm özetlenemediğinde
/// bunu **sessizce yutmak** eski davranıştı (ham 600 karakter birleştirmeye
/// giriyordu); artık kullanıcıya söylenir.
nonisolated struct SummaryResult: Sendable {
    var ozet: Ozet
    var topics: [TopicSegment]
    var skippedChunks: Int
}

nonisolated protocol Intelligent: Sendable {
    var availability: ModelAvailability { get }

    /// **Zorunlu adım.** Türkçe çıktı noktalamasız gelir (RESEARCH.md §2);
    /// noktalamasız transkript hem okunmaz hem özet kalitesini düşürür.
    @concurrent func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment]

    /// Map-reduce özetleme. Transkript asla kırpılmaz.
    ///
    /// `context` toplantı tarihini ve sorumlu kişi için kapalı isim listesini
    /// taşır; ikisi de isteğe bağlıdır (takvim kapalıysa liste boştur).
    ///
    /// `variation` kullanıcı özeti beğenmeyip **yeniden ürettiğinde** açılır:
    /// örnekleme daha serbest yapılır, yoksa aynı istem büyük olasılıkla aynı
    /// özeti verir ve düğme bozukmuş gibi görünür. İlk geçiş her zaman
    /// varsayılan örneklemeyle çalışır — RESEARCH.md §23-24 ölçümleri onunla
    /// alındı.
    @concurrent func summarize(_ segments: [Segment],
                   context: SummaryContext,
                   variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws
        -> SummaryResult

    /// Toplantı sohbeti: transkript üzerinde soru-cevap, map-reduce ile.
    @concurrent func answer(question: String, over segments: [Segment]) async throws -> String

    /// Transkriptten başlık üretir. Pencere başlığı **okunmaz** — sandbox'lı
    /// uygulamada ekran kaydı izni ister (RESEARCH.md §11).
    @concurrent func generateTitle(from segments: [Segment]) async -> String?

    /// Konu başlıkları varsa başlık onlardan üretilir — ilk parça toplantının
    /// tamamını temsil etmiyor.
    @concurrent func generateTitle(from segments: [Segment],
                       topics: [TopicSegment]) async -> String?
}
