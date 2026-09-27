import Foundation

/// Diarization'ın tek çıktısı: "bu aralıkta şu küme konuştu". Küme kimliği
/// motorun iç adıdır ("S1", "S2"); kullanıcıya **hiçbir zaman** gösterilmez.
nonisolated struct SpeakerTurn: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String

    var duration: TimeInterval { max(0, end - start) }
}

/// Bir kanalın konuşmacı ayrımı: turlar ve küme başına ortalama ses izi.
nonisolated struct Diarization: Sendable, Equatable {
    var turns: [SpeakerTurn]
    /// Küme kimliği → gömme vektörü (WeSpeaker, 256 boyut). Kişileri
    /// toplantılar arasında tanımak için (`VoiceMatcher`).
    var embeddings: [String: [Float]] = [:]
}

/// Konuşmacı ayrımı motoru. Testte sahtelenir.
nonisolated protocol Diarizing: Sendable {
    /// Motor bu makinede kullanılabilir mi (modeller pakette mi)?
    var isAvailable: Bool { get }

    /// Kaydın **tek kanalında** kim ne zaman konuştu. Kanallar asla
    /// karıştırılmaz (kural #11): diarization yalnızca istenen şeridi görür.
    ///
    /// `@concurrent` **sözleşmededir** (kural #13): 60 dakikalık bir kaydın
    /// segmentasyonu ve gömülmesi ana iş parçacığında koşamaz.
    @concurrent func turns(url: URL, channel: Channel,
                           progress: @Sendable @escaping (Double) -> Void) async throws
        -> Diarization
}

/// Diarization turlarını transkripte uygulayan **politika**. Motordan
/// bağımsız ve saf: hangi kanal ayrılır, tur kelimeye nasıl atanır, küme
/// nasıl adlandırılır.
///
/// **Ad tahmin edilmez.** Kümeler "Katılımcı 1", "Katılımcı 2" olur; kimin kim
/// olduğunu kullanıcı transkriptten verir ("o etiketin tümü" tek hamlede
/// bütün kümeyi adlandırır). Kendinden emin yanlış bir ad, numaralı bir
/// etiketten kötüdür.
nonisolated enum SpeakerSeparation {

    /// Bu kadar konuşmadan az olan küme gürültü sayılır ve komşusuna katılır.
    /// Tek kelimelik bir "hı hı" ayrı bir katılımcı değildir.
    static let minimumSpeech: TimeInterval = 3
    /// Bir konuşmacı değişimi en az bu kadar kelime **ya da** bu kadar süre
    /// taşımalı; yoksa bir önceki tura katılır. Segment ortasında tek kelimelik
    /// sıçramalar transkripti okunmaz hâle getiriyordu.
    static let minimumRunWords = 3
    static let minimumRunDuration: TimeInterval = 1.0

    /// Hangi kanal ayrılmalı? **Kanıtla** seçilir, kanal indeksiyle değil
    /// (COMPETITION.md §4.13):
    ///  - Sistem kanalında konuşma varsa uzak katılımcılar oradadır → sistem.
    ///    Mikrofon kanalı o zaman kullanıcının kendisidir; ayırmak yalnızca
    ///    hoparlörden sızan karşı tarafı sahte bir konuşmacıya çevirirdi.
    ///  - Sistem sessiz, mikrofonda konuşma varsa yüz yüze toplantıdır;
    ///    odadaki herkes aynı mikrofondadır → mikrofon.
    ///  - İçe aktarılan mono ses zaten `.system` olarak çözülür → sistem.
    static func channel(for segments: [Segment]) -> Channel? {
        if segments.contains(where: { $0.channel == .system }) { return .system }
        if segments.contains(where: { $0.channel == .mic }) { return .mic }
        return nil
    }

    /// Turları `channel` kanalındaki segmentlere uygular; diğer kanal olduğu
    /// gibi kalır. Tek küme çıkarsa hiçbir şey değişmez — etiket zaten doğrudur.
    static func apply(_ turns: [SpeakerTurn], to segments: [Segment],
                      channel: Channel) -> [Segment] {
        separate(turns, to: segments, channel: channel).segments
    }

    /// `apply` + kümelerin aldığı son etiketler.
    ///
    /// - Parameter known: ses izinden tanınan kümeler (küme → kişi). Tanınan
    ///   küme kişinin adını alır, geri kalanlar "Katılımcı N" olarak
    ///   numaralanır. Tek küme bile tanınmışsa adlandırılır.
    /// - Returns: `labels`, küme → verilen etiket. Tek ve tanınmamış kümede
    ///   kanal etiketidir; kullanıcı onu adlandırınca sesi öğrenilir.
    static func separate(_ turns: [SpeakerTurn], to segments: [Segment],
                         channel: Channel, known: [String: String] = [:])
        -> (segments: [Segment], labels: [String: String]) {
        let kept = significant(turns)
        let clusters = Set(kept.map(\.speaker))
        guard clusters.count > 1 else {
            guard let cluster = clusters.first else { return (segments, [:]) }
            guard let name = known[cluster] else {
                return (segments, [cluster: channel.speaker])
            }
            let renamed = segments.map {
                $0.channel == channel ? relabeled($0, as: name) : $0
            }
            return (renamed, [cluster: name])
        }

        // Önce her kelimenin kümesi bulunur, adlar ondan sonra verilir:
        // numara **ilk konuşma sırasıdır** ve atamadan önce bilinmez.
        var split: [(segment: Segment, cluster: String?)] = []
        for segment in segments {
            guard segment.channel == channel else {
                split.append((segment, nil))
                continue
            }
            split.append(contentsOf: runs(of: segment, turns: kept))
        }

        let names = labels(for: split.filter { $0.segment.channel == channel },
                           channel: channel, known: known)
        let result = split.map { item in
            guard let cluster = item.cluster, let name = names[cluster] else {
                return item.segment
            }
            return relabeled(item.segment, as: name)
        }
        .sorted { $0.start < $1.start }
        return (result, names)
    }

    // MARK: - Adımlar

    /// Konuşması `minimumSpeech`'in altında kalan kümeler atılır.
    static func significant(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var speech: [String: TimeInterval] = [:]
        for turn in turns { speech[turn.speaker, default: 0] += turn.duration }
        return turns
            .filter { speech[$0.speaker, default: 0] >= minimumSpeech && $0.duration > 0 }
            .sorted { $0.start < $1.start }
    }

    /// Kelimenin ortasını içeren tur; yoksa en yakın tur. Tur hiç yoksa nil.
    static func cluster(at start: TimeInterval, _ end: TimeInterval,
                        in turns: [SpeakerTurn]) -> String? {
        let middle = (start + end) / 2
        if let containing = turns.first(where: { $0.start <= middle && middle <= $0.end }) {
            return containing.speaker
        }
        return turns.min { distance(middle, to: $0) < distance(middle, to: $1) }?.speaker
    }

    private static func distance(_ time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        time < turn.start ? turn.start - time : max(0, time - turn.end)
    }

    /// Segmenti kelime düzeyinde konuşmacı değişimlerinden böler.
    ///
    /// **Kelime düzeyi şart:** `DictationTranscriber` segmentleri 5–10 sn'dir
    /// ve iki turu birden kapsayabilir; segmente tek konuşmacı atamak orada
    /// yanlış etiketler (§4.13). Kelime zamanı yoksa segment, en çok örtüştüğü
    /// kümeye bütün olarak verilir.
    static func runs(of segment: Segment,
                     turns: [SpeakerTurn]) -> [(segment: Segment, cluster: String?)] {
        guard !segment.words.isEmpty else {
            return [(segment, dominant(segment.start, segment.end, in: turns))]
        }

        var groups: [(cluster: String?, words: [WordTiming])] = []
        for word in segment.words {
            let owner = cluster(at: word.start, word.end, in: turns)
            if let last = groups.last, last.cluster == owner {
                groups[groups.count - 1].words.append(word)
            } else {
                groups.append((owner, [word]))
            }
        }
        groups = merged(groups)

        guard groups.count > 1 else { return [(segment, groups.first?.cluster)] }
        return groups.enumerated().map { index, group in
            let scores = group.words.compactMap(\.confidence)
            let piece = Segment(
                channel: segment.channel,
                speaker: segment.speaker,
                text: group.words.map(\.text).joined(separator: " "),
                // Uçlar segmentin kendisinden: kelime zamanları segment
                // sınırlarının biraz içinde kalır, kapsama kısalmasın.
                start: index == 0 ? segment.start : group.words.first!.start,
                end: index == groups.count - 1 ? segment.end : group.words.last!.end,
                confidence: scores.isEmpty ? segment.confidence
                                           : scores.reduce(0, +) / Double(scores.count),
                words: group.words)
            return (piece, group.cluster)
        }
    }

    /// Kısa sıçramalar bir önceki gruba (baştaysa sonrakine) katılır.
    private static func merged(_ groups: [(cluster: String?, words: [WordTiming])])
        -> [(cluster: String?, words: [WordTiming])] {
        var result = groups
        var index = 0
        while result.count > 1, index < result.count {
            let words = result[index].words
            let duration = (words.last?.end ?? 0) - (words.first?.start ?? 0)
            let isShort = words.count < minimumRunWords && duration < minimumRunDuration
            guard isShort else { index += 1; continue }
            let target = index > 0 ? index - 1 : index + 1
            if target < index {
                result[target].words.append(contentsOf: words)
            } else {
                result[target].words.insert(contentsOf: words, at: 0)
            }
            result.remove(at: index)
            // Katılım iki komşuyu aynı kümede yan yana bırakabilir.
            index = 0
            result = coalesced(result)
        }
        return result
    }

    private static func coalesced(_ groups: [(cluster: String?, words: [WordTiming])])
        -> [(cluster: String?, words: [WordTiming])] {
        var result: [(cluster: String?, words: [WordTiming])] = []
        for group in groups {
            if let last = result.last, last.cluster == group.cluster {
                result[result.count - 1].words.append(contentsOf: group.words)
            } else {
                result.append(group)
            }
        }
        return result
    }

    /// Aralıkla en çok örtüşen küme; örtüşme yoksa en yakın tur.
    static func dominant(_ start: TimeInterval, _ end: TimeInterval,
                         in turns: [SpeakerTurn]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 { overlap[turn.speaker, default: 0] += shared }
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        return cluster(at: start, end, in: turns)
    }

    /// Kümelere ad verir.
    ///
    ///  - **Sistem kanalı:** hepsi uzak katılımcıdır — ilk konuşma sırasına
    ///    göre "Katılımcı 1", "Katılımcı 2"…
    ///  - **Mikrofon (yüz yüze):** en çok konuşan küme "Ben" kalır — mikrofon
    ///    kaydı tutanın önündedir; geri kalanlar numaralanır. Yanılırsa
    ///    kullanıcı tek hamlede düzeltir.
    static func labels(for items: [(segment: Segment, cluster: String?)],
                       channel: Channel,
                       known: [String: String] = [:]) -> [String: String] {
        var order: [String] = []
        var speech: [String: TimeInterval] = [:]
        for item in items {
            guard let cluster = item.cluster else { continue }
            if !order.contains(cluster) { order.append(cluster) }
            speech[cluster, default: 0] += item.segment.end - item.segment.start
        }
        guard order.count > 1 else { return [:] }

        // Ses izinden tanınanlar önce; numaralar geri kalanlara verilir.
        var names: [String: String] = [:]
        var others = order
        for cluster in order {
            guard let person = known[cluster] else { continue }
            names[cluster] = person
            others.removeAll { $0 == cluster }
        }
        // Yüz yüze toplantıda sahibin sesi tanınmadıysa en çok konuşan "Ben".
        if channel == .mic, !names.values.contains(Channel.mic.speaker),
           let owner = speech.filter({ others.contains($0.key) })
               .max(by: { $0.value < $1.value })?.key {
            names[owner] = Channel.mic.speaker
            others.removeAll { $0 == owner }
        }
        for (index, cluster) in others.enumerated() {
            names[cluster] = numbered(index + 1)
        }
        return names
    }

    /// Numaralı küme etiketi: "Katılımcı 2".
    static func numbered(_ number: Int) -> String {
        "\(Channel.system.speaker) \(number)"
    }

    private static func relabeled(_ segment: Segment, as speaker: String) -> Segment {
        Segment(channel: segment.channel, speaker: speaker, text: segment.text,
                start: segment.start, end: segment.end,
                confidence: segment.confidence, words: segment.words)
    }
}
