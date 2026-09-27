import Foundation

/// Transkripti bağlam penceresine sığan parçalara böler.
///
/// **Kırpma yasak.** Önceki ora'da `MAX_TRANSCRIPT_CHARS = 14_000` yüzünden
/// 60 dakikalık toplantının %75'i sessizce çöpe gidiyordu. Burada her karakter
/// bir parçaya girer; hiçbir şey atılmaz.
///
/// Bağlam penceresi sabit değil: `SystemLanguageModel.contextSize` macOS 26'da
/// 4096, macOS 27'de 8192 token (RESEARCH.md §41). Sınırlar bu yüzden
/// pencereden hesaplanır.
///
/// RESEARCH.md §3'teki "4 karakter ≈ 1 token" oranı **iyimserdi**: gerçek bir
/// Türkçe toplantı transkriptinde (teknik terim, kesme işareti, yoğun ek)
/// ölçülen oran **2,45 karakter/token** (RESEARCH.md §23). 4096'lık pencerede
/// 10.000 karakterlik parça 4.089 token ediyor ve parça istemiyle
/// birlikte pencereyi taşırıyordu — 60 dakikalık bir toplantıda **her parça**
/// düşüyordu.
///
/// Sınırlar bu ölçülen orandan hesaplanır ve üretilecek çıktıya pay bırakır.
///
/// macOS 27'de ölçülen bütçe (RESEARCH.md §41, `tokenCount(for:)`): talimat
/// 161, eski birleşik `ParcaOzeti` şeması 482, istem gövdesi 458 token — sabit kısım
/// **~1.100 token**, parça ne olursa olsun. Yeni sürümün tokenizer'ı Türkçe'de
/// daha verimli (**3,1–3,2 krk/token**); 12.000 krk ≈ 3.800 token. Sağlıklı
/// bir parçanın çıktısı 400–770 token, toplam doluluk ~5.600 / 8.192.
nonisolated enum TranscriptChunker {

    /// Sınırların ölçüldüğü pencere (RESEARCH.md §23).
    static let measuredContextSize = 4096
    /// Özetleme parçası, 4096'lık pencerede: 6.000 krk ≈ 2.450 token (macOS 26
    /// tokenizer'ı); kalan ~1.650 token istem, şema ve çıktıya.
    static let summaryLimit = 6_000
    /// Noktalama parçası — çıktı girdiyle **aynı boyutta** olacağı için daha dar:
    /// 3.500 krk ≈ 1.430 token girdi + aynı kadar çıktı + istem.
    static let punctuationLimit = 3_500

    /// `contextSize` token'lık pencereye göre özetleme parçası. İstem, girdi
    /// ve çıktı payı pencereyle **orantılı** büyür — büyüyen parça daha çok
    /// konu ve daha uzun not üretir, sabit bir çıktı payı yetmez.
    static func summaryLimit(contextSize: Int) -> Int {
        scaled(summaryLimit, to: contextSize)
    }

    /// `contextSize` token'lık pencereye göre noktalama parçası.
    static func punctuationLimit(contextSize: Int) -> Int {
        scaled(punctuationLimit, to: contextSize)
    }

    private static func scaled(_ limit: Int, to contextSize: Int) -> Int {
        max(1, limit * contextSize / measuredContextSize)
    }

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
