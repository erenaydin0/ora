import Foundation
import FoundationModels

/// Toplantı özeti — `@Generable` şema. Elle JSON ayrıştırma yazılmaz.
@Generable
struct Ozet: Sendable, Equatable {

    @Guide(description: "Toplantının 2-3 cümlelik Türkçe özeti")
    var genelBakis: String

    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6))
    var kararlar: [String]

    @Generable
    struct Aksiyon: Sendable, Equatable, Identifiable {
        @Guide(description: "Sorumlu kişinin adı, belli değilse 'belirtilmedi'")
        var kisi: String
        @Guide(description: "Yapılacak iş")
        var gorev: String
        /// **Şemadan çıkarma.** Önceki ora'da bu alan istenmediği için DB'deki
        /// `deadline` sütunu hep NULL kalıyordu.
        @Guide(description: "Son tarih, belirtilmemişse 'belirtilmedi'")
        var sonTarih: String

        var id: String { "\(kisi)-\(gorev)" }
    }

    @Guide(description: "Aksiyon maddeleri", .maximumCount(8))
    var aksiyonlar: [Aksiyon]
}

/// Bir konu bloğunun başlığı. Zaman aralığı LLM'e sorulmaz — parçanın
/// segmentlerinden bilinir.
@Generable
struct KonuBasligi: Sendable {
    @Guide(description: "Bu bölümün 2-5 kelimelik Türkçe başlığı")
    var baslik: String
}

/// `topic_segments` tablosunun karşılığı (tablo Faz 5'te).
struct TopicSegment: Sendable, Identifiable, Hashable {
    let title: String
    let start: TimeInterval
    let end: TimeInterval
    var id: String { "\(start)-\(title)" }

    var timeLabel: String {
        let total = Int(start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
