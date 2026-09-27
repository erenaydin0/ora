import Foundation

/// Bir kelimenin zaman aralığı ve güven skoru.
nonisolated struct WordTiming: Sendable, Hashable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}

/// Transkriptin en küçük birimi. Kayıt başlangıcına göre saniye cinsinden konumlanır.
nonisolated struct Segment: Sendable, Identifiable, Hashable {
    let channel: Channel
    let speaker: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
    let words: [WordTiming]

    var id: String { "\(channel.rawValue)-\(start)-\(end)" }

    var timeLabel: String {
        let total = Int(start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Özet maddelerini transkriptteki yerlerine bağlayan dizin — "alıntı bağı"
/// (COMPETITION.md §4.3).
///
/// Model paraphrase ettiği için birebir arama işe yaramaz; ölçüt **ağırlıklı
/// kelime örtüşmesi**. Kelimeler `FoundationIntelligence.words(of:)` ile
/// normalleştirilir (Türkçe küçük harf, diakritik düşürme, ilk 5 harf) —
/// ekler yüzünden kaçan eşleşmeleri bu kaba gövdeleme kurtarır.
///
/// **Ağırlık şart:** düz sayım "yapmak", "olarak", "belirlemek" gibi her yerde
/// geçen kelimeleri kanıt sayıp yanlış yere atlıyordu. Kelime kaç segmentte
/// geçiyorsa o kadar değersizdir (IDF). Ölçüm: eşleşme oranı %57 → %86 ve
/// eşleşmeler ayırt edici kelimelerle taşınıyor (RESEARCH.md §25.2).
///
/// Eşiğin altında `nil` döner ve madde **tıklanabilir olmaz**: yanlış bir yere
/// atlamak, hiç atlamamaktan kötüdür.
nonisolated struct TranscriptIndex {

    private let lines: [(segment: Segment, words: Set<String>)]
    private let weight: [String: Double]

    /// Ölçümle seçildi (RESEARCH.md §25.2). 0,6 gerçek eşleşmeleri de eliyor,
    /// 0,4 zayıf kanıtla atlıyor.
    private static let threshold = 0.5
    /// Üç kelimeden kısa maddede kanıt yetersiz kalıyor.
    private static let minimumWords = 3

    init(_ segments: [Segment]) {
        lines = segments.map { ($0, Set(FoundationIntelligence.words(of: $0.text))) }
        var frequency: [String: Int] = [:]
        for line in lines {
            for word in line.words { frequency[word, default: 0] += 1 }
        }
        let total = Double(max(segments.count, 2))
        weight = frequency.mapValues { max(0, log(total / Double(1 + $0))) }
    }

    var isEmpty: Bool { lines.isEmpty }

    /// Maddenin geçtiği segment; bulunamazsa `nil`.
    func match(_ text: String) -> Segment? {
        let needle = Set(FoundationIntelligence.words(of: text))
        guard needle.count >= Self.minimumWords, !lines.isEmpty else { return nil }
        // Transkriptte hiç geçmeyen kelime ne kanıttır ne de gürültü:
        // toplam ağırlık yalnızca geçen kelimelerden kurulur.
        let total = needle.reduce(0.0) { $0 + (weight[$1] ?? 0) }
        guard total > 0 else { return nil }

        var best: Segment?
        var bestScore = 0.0
        for line in lines where !line.words.isEmpty {
            let hit = needle.intersection(line.words).reduce(0.0) { $0 + (weight[$1] ?? 0) }
            let score = hit / total
            if score > bestScore { bestScore = score; best = line.segment }
        }
        return bestScore >= Self.threshold ? best : nil
    }
}

/// Transkripsiyonun ilerlemesi ve sonucu.
nonisolated enum TranscriptionProgress: Sendable {
    case preparing
    case downloadingLocale(Double)
    case transcribing(Double)
    case finished([Segment])
    case failed(OraError)
}

nonisolated protocol Transcribing: Sendable {
    /// Diskteki stereo WAV üzerinden tam geçiş. Nihai gerçek budur. Her kanal
    /// kendi diliyle çözülür (COMPETITION.md §4.8).
    @concurrent func transcribe(url: URL,
                    locales: ChannelLocales,
                    vocabulary: [String],
                    progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment]
}

/// Kanal başına transkripsiyon dili (COMPETITION.md §4.8).
///
/// Yabancı müşteriyle toplantıda kullanıcı Türkçe, karşı taraf İngilizce
/// konuşur. İki kanal zaten ayrı `SpeechAnalyzer` ile çözüldüğü için her
/// birine kendi dilini vermek mimariden bedava gelir — tek kanallı
/// rakiplerin yapısal olarak yapamadığı bir şey.
nonisolated struct ChannelLocales: Sendable, Equatable {
    /// Kanal 0: kullanıcının kendisi.
    var mic: Locale
    /// Kanal 1: toplantı uygulamasının sesi, yani karşı taraf.
    var system: Locale

    init(mic: Locale, system: Locale) {
        self.mic = mic
        self.system = system
    }

    /// İki kanal aynı dilde.
    init(_ both: Locale) {
        self.init(mic: both, system: both)
    }

    func locale(for channel: Channel) -> Locale {
        channel == .mic ? mic : system
    }

    /// Hazırlanması gereken diller, tekrarsız.
    var distinct: [Locale] {
        mic.identifier == system.identifier ? [mic] : [mic, system]
    }

    var isMixed: Bool { distinct.count > 1 }

    var label: String {
        isMixed ? "mic \(mic.identifier) · sistem \(system.identifier)" : mic.identifier
    }
}

/// Analiz motoru kurulurken çıkan, kullanıcıya `OraError.transcriptionFailed`
/// içinde ulaşan iç hata.
nonisolated struct TranscriptionSetupError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
