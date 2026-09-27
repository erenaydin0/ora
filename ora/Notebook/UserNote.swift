import Foundation

/// Kullanıcının kendi notu ya da kayıt sırasında işaretlediği "önemli an"
/// (COMPETITION.md §4.6, §4.9).
///
/// **Not kullanıcınındır, model onu yazmaz.** Kayıt sırasında yalnızca yazı
/// yazılır (kural #1: LLM yok); kayıt bittikten sonra özetleyici notun
/// **altına** transkriptten ayrıntı ekler (`details`). Arayüz ikisini tonla
/// ayırır: kullanıcının metni `.oraInk`, eklenen ayrıntı `.oraInkMuted`.
nonisolated struct UserNote: Sendable, Identifiable, Hashable {

    enum Kind: String, Sendable, Codable {
        /// Kullanıcının yazdığı madde.
        case note
        /// Kayıt sırasında işaretlenen an. Metni boş olabilir; o zaman o anda
        /// ne konuşulduğunu zenginleştirme yazar.
        case mark
    }

    let id: Int64
    var kind: Kind
    var text: String
    /// Kayıt başından saniye. Kayıt dışında (sonradan) yazılan notta `nil` —
    /// o zaman transkriptteki yeri kelime eşleştirmesiyle bulunur.
    var at: TimeInterval?
    /// Transkriptten eklenen ayrıntı. Kullanıcının yazdığı değil.
    var details: [String]

    var isMark: Bool { kind == .mark }

    /// Görünen metin: işaretin metni yoksa "Önemli an".
    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, isMark { return "Önemli an" }
        return trimmed
    }

    var timeLabel: String? { at.map(Self.timeLabel) }

    /// Bir saati aşan kayıtta `MM:SS` yanlış okunur (90 dakika "90:12").
    static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Notu transkriptteki yerine bağlayan saf kurallar. Model çağrısı yapmaz;
/// hat ve arayüz aynı kuralı kullanır.
nonisolated enum NoteAnchor {

    /// İşaret konuşmanın **arkasından** gelir: kullanıcı önemli bir şey duyar,
    /// sonra düğmeye basar. Bu yüzden işaretten önceki pay geniş, sonraki dar.
    static let lookBehind: TimeInterval = 90
    static let lookAhead: TimeInterval = 20
    /// Zaman damgasız notun transkriptte bulunmuş yerinin çevresi.
    static let around: TimeInterval = 45
    /// Kelime eşleştirmesinin eşiği: notun ağırlığının yarısı aynı satırda
    /// geçmeli. Alıntı bağıyla aynı değer (RESEARCH.md §25.2); not kısa
    /// olduğu için oradaki "en az üç kelime" koşulu burada yok.
    static let threshold = 0.5

    /// İşaretlenen anın satırı: işaret anında konuşulan satır, yoksa
    /// hemen önceki. İşaret satırın bitiminden birkaç saniye sonra da
    /// basılabilir (tepki süresi).
    static func segment(at time: TimeInterval, in segments: [Segment]) -> Segment? {
        if let during = segments.last(where: { $0.start <= time && time <= $0.end + 3 }) {
            return during
        }
        return segments.last { $0.start <= time } ?? segments.first
    }

    /// Notun anlattığı transkript bölümü.
    ///
    /// Zamanlı not ya da işaret: `at − lookBehind … at + lookAhead`.
    /// Zamansız not: kelime eşleştirmesiyle bulunan satırın çevresi; bulunamazsa
    /// boş — **yanlış bir yere bağlamak hiç bağlamamaktan kötüdür.**
    static func window(for note: UserNote, in segments: [Segment]) -> [Segment] {
        let center: TimeInterval
        let before: TimeInterval
        let after: TimeInterval
        if let at = note.at {
            center = at
            before = lookBehind
            after = lookAhead
        } else if let match = bestMatch(note.text, in: segments) {
            center = match.start
            before = around
            after = around
        } else {
            return []
        }
        let slice = segments.filter { $0.end >= center - before && $0.start <= center + after }
        if !slice.isEmpty { return slice }
        // Kayıt sessizken basılan işaret: en yakın önceki satırlar.
        return Array(segments.filter { $0.start <= center }.suffix(4))
    }

    /// Kısa notun en iyi eşleştiği satır — IDF ağırlıklı kelime örtüşmesi.
    static func bestMatch(_ text: String, in segments: [Segment]) -> Segment? {
        let needle = Set(FoundationIntelligence.words(of: text))
        guard !needle.isEmpty, !segments.isEmpty else { return nil }
        let lines = segments.map { ($0, Set(FoundationIntelligence.words(of: $0.text))) }
        var frequency: [String: Int] = [:]
        for (_, words) in lines { for word in words { frequency[word, default: 0] += 1 } }
        let count = Double(max(segments.count, 2))
        func weight(_ word: String) -> Double {
            guard let seen = frequency[word] else { return 0 }
            return max(0.05, log(count / Double(seen)) + 0.05)
        }
        let total = needle.reduce(0.0) { $0 + weight($1) }
        guard total > 0 else { return nil }
        var best: Segment?
        var bestScore = 0.0
        for (segment, words) in lines {
            let score = needle.intersection(words).reduce(0.0) { $0 + weight($1) } / total
            if score > bestScore { bestScore = score; best = segment }
        }
        return bestScore >= threshold ? best : nil
    }

    /// Pencere istem sınırını aşıyorsa merkeze **en uzak** uçtan satır
    /// atılır. Bu kırpma transkripti değil, tek bir notun bağlamını daraltır;
    /// transkriptin tamamı özetlemede zaten parçalanarak işlenir.
    static func trimmed(_ window: [Segment], limit: Int,
                        center: TimeInterval?) -> [Segment] {
        var lines = window
        let middle = center ?? lines.map(\.start).reduce(0, +) / Double(max(lines.count, 1))
        while lines.count > 1, TranscriptChunker.render(lines).count > limit {
            let head = abs(lines[0].start - middle)
            let tail = abs(lines[lines.count - 1].start - middle)
            if head > tail { lines.removeFirst() } else { lines.removeLast() }
        }
        return lines
    }

    /// İşaretli satırların kimlikleri — transkriptte küçük bayrak çizilir.
    static func markedIDs(_ times: [TimeInterval], in segments: [Segment]) -> Set<Segment.ID> {
        Set(times.compactMap { segment(at: $0, in: segments)?.id })
    }
}

/// Kullanıcının notlarının özet istemine giden hâli.
///
/// **Varsayılan boştur ve boşken istem bayt bayt aynı kalır** — §23-37
/// ölçümleri notsuz istemle alındı (`SummaryShapeTests`).
nonisolated struct NotebookHints: Sendable, Equatable {
    /// Kullanıcının yazdığı notlar, yazıldığı sırayla.
    var notes: [String] = []
    /// İşaretlenen anlarda konuşulan satırların metni.
    var markedLines: [String] = []

    var isEmpty: Bool { notes.isEmpty && markedLines.isEmpty }

    /// Pencere dar (4096 token): notlar istemi taşırmasın. Sınır, özetleme
    /// parçasının altıda biri kadar; aşan not kırpılmaz, **dışarıda kalır** ve
    /// zaten notun kendisi olarak özetin yanında durur.
    static let characterBudget = 900

    static func from(_ notes: [UserNote], segments: [Segment]) -> NotebookHints {
        var budget = characterBudget
        var texts: [String] = []
        for note in notes where note.kind == .note {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= budget else { continue }
            budget -= text.count
            texts.append(text)
        }
        var lines: [String] = []
        for mark in notes where mark.kind == .mark {
            guard let at = mark.at, let segment = NoteAnchor.segment(at: at, in: segments),
                  !lines.contains(segment.text), segment.text.count <= budget else { continue }
            budget -= segment.text.count
            lines.append(segment.text)
        }
        return NotebookHints(notes: texts, markedLines: lines)
    }
}
