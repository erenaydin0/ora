import Foundation

/// Transkripti bağlam penceresine sığan parçalara böler.
///
/// **Kırpma yasak.** Önceki ora'da `MAX_TRANSCRIPT_CHARS = 14_000` yüzünden
/// 60 dakikalık toplantının %75'i sessizce çöpe gidiyordu. Burada her karakter
/// bir parçaya girer; hiçbir şey atılmaz.
///
/// Bağlam penceresi 4096 token. RESEARCH.md §3'teki "4 karakter ≈ 1 token"
/// oranı **iyimserdi**: gerçek bir Türkçe toplantı transkriptinde (teknik terim,
/// kesme işareti, yoğun ek) ölçülen oran **2,45 karakter/token** (RESEARCH.md
/// §23). 10.000 karakterlik parça 4.089 token ediyor ve `ParcaOzeti` istemiyle
/// birlikte pencereyi taşırıyordu — 60 dakikalık bir toplantıda **her parça**
/// düşüyordu.
///
/// Sınırlar bu ölçülen orandan hesaplanır ve üretilecek çıktıya pay bırakır.
nonisolated enum TranscriptChunker {

    /// Özetleme parçası: 6.000 krk ≈ 2.450 token; istem ~300, çıktıya ~1.300 pay.
    static let summaryLimit = 6_000
    /// Noktalama parçası — çıktı girdiyle **aynı boyutta** olacağı için daha dar:
    /// 3.500 krk ≈ 1.430 token girdi + aynı kadar çıktı + istem.
    static let punctuationLimit = 3_500

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
