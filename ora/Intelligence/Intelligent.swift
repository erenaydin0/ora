import Foundation
import FoundationModels

/// Apple Intelligence'ın bu makinedeki durumu.
enum ModelAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    var isAvailable: Bool { self == .available }

    var turkishMessage: String {
        switch self {
        case .available:                  ""
        case .deviceNotEligible:          "Bu Mac Apple Intelligence'ı desteklemiyor"
        case .appleIntelligenceNotEnabled: "Apple Intelligence kapalı"
        case .modelNotReady:              "Apple Intelligence modeli henüz hazır değil"
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
        }
    }
}

/// Özetleme aşamalarının ilerlemesi.
enum IntelligenceStage: Sendable, Equatable {
    case punctuating(Double)
    case summarizing(Double)
}

protocol Intelligent: Sendable {
    var availability: ModelAvailability { get }

    /// **Zorunlu adım.** Türkçe çıktı noktalamasız gelir (RESEARCH.md §2);
    /// noktalamasız transkript hem okunmaz hem özet kalitesini düşürür.
    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment]

    /// Map-reduce özetleme. Transkript asla kırpılmaz.
    func summarize(_ segments: [Segment],
                   progress: @Sendable @escaping (Double) -> Void) async throws -> (Ozet, [TopicSegment])
}
