import Foundation

/// Transkripti bağlam penceresine sığan parçalara böler.
///
/// **Kırpma yasak.** Önceki ora'da `MAX_TRANSCRIPT_CHARS = 14_000` yüzünden
/// 60 dakikalık toplantının %75'i sessizce çöpe gidiyordu. Burada her karakter
/// bir parçaya girer; hiçbir şey atılmaz.
///
/// Bağlam penceresi 4096 token, Türkçe'de kabaca 4 karakter ≈ 1 token
/// (RESEARCH.md §3). Sınırlar talimat ve üretilecek çıktı için pay bırakır.
enum TranscriptChunker {

    /// Özetleme parçası — girdi büyük, çıktı kısa.
    static let summaryLimit = 10_000
    /// Noktalama parçası — çıktı girdiyle **aynı boyutta** olacağı için yarısı kadar.
    static let punctuationLimit = 4_000

    /// Segmentleri, birleşik metni `limit`i aşmayan gruplara böler.
    static func chunks(of segments: [Segment], limit: Int) -> [[Segment]] {
        var result: [[Segment]] = []
        var current: [Segment] = []
        var length = 0

        for segment in segments {
            let cost = line(for: segment).count + 1
            if !current.isEmpty, length + cost > limit {
                result.append(current)
                current = []
                length = 0
            }
            current.append(segment)
            length += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Modele verilecek biçim: her satır bir konuşmacı repliği.
    static func render(_ segments: [Segment]) -> String {
        segments.map(line(for:)).joined(separator: "\n")
    }

    static func line(for segment: Segment) -> String {
        "\(segment.speaker): \(segment.text)"
    }

    /// Uzun metni cümle sınırlarından `limit` altına böler (kısmi özetleri
    /// birleştirirken gerekir).
    static func split(text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        for sentence in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + sentence.count + 1 > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + sentence
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
