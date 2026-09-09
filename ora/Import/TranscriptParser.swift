import Foundation

/// Dışarıdan gelen transkript metnini `Segment` dizisine çevirir.
///
/// Girdi kullanıcının elindeki her şey olabilir: Teams/Zoom'un `.vtt` dökümü,
/// bir altyazı dosyası (`.srt`), düz metin, Markdown notu ya da panodan
/// yapıştırılmış ham konuşma. Bu yüzden **tek bir biçim dayatılmaz**; metin
/// neye benziyorsa ona göre okunur ve okunamayan satır sessizce atılmaz —
/// hiçbir şey çözümlenemezse çağıran Türkçe bir hata alır.
///
/// Üç şeyi üretmek zorundayız, çünkü hattın geri kalanı bunlara dayanıyor:
///
/// 1. **Artan ve benzersiz `start`.** `MeetingStore` bir satırı
///    `(meeting_id, start_time, channel)` ile güncelliyor ve siliyor; iki
///    satır aynı ana denk gelirse düzeltme yanlış satırı yazar.
/// 2. **Parçalanabilir uzunluk.** `TranscriptChunker` segment sınırından
///    böler; tek parça hâlinde yapıştırılmış 20.000 karakterlik bir metin tek
///    segment kalırsa 4096 token'lık pencereyi taşırır ve o parça sessizce
///    düşer. Uzun paragraf cümle sınırından bölünür.
/// 3. **Konuşmacı ve kanal.** Kanal fiziksel gerçektir (kural #11) ama içe
///    aktarılan metinde fiziksel kanal yoktur: kullanıcının kendi adı
///    (`OraSettings.userDisplayName`) ya da "Ben" mikrofon kanalına, geri
///    kalan herkes sistem kanalına yazılır. **Etiket olarak kaynaktaki gerçek
///    ad korunur** — özetleyici `kisi` alanını bu adlardan çıkarıyor ve bu,
///    içe aktarmanın kendi kaydımıza göre en büyük kazancı.
nonisolated enum TranscriptParser {

    /// Zaman damgası olmayan kaynaklarda satırlara süre uydurmak için konuşma
    /// hızı varsayımı. Kesin olması gerekmiyor: süre yalnızca sıralama, oynatıcı
    /// olmayan bir kayıtta görünen etiket ve toplantı uzunluğu için kullanılıyor.
    static let charactersPerSecond = 15.0
    /// Tek kelimelik satırların üst üste binmemesi için taban süre.
    static let minimumLineDuration = 1.5
    /// Bundan uzun bir satır cümle sınırından bölünür (bkz. gerekçe 2).
    static let lineLimit = 600

    /// Kanal etiketi olarak mikrofona yazılacak adlar. Kullanıcının kendi adı
    /// ayrıca eklenir.
    private static let selfNames = ["ben", "me", "i"]

    // MARK: - Giriş

    static func parse(_ raw: String, userName: String = "") -> [Segment] {
        let text = normalized(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // Zaman aralığı işareti varsa kaynak bir altyazı dosyasıdır (VTT/SRT);
        // orada konuşmacı ve zaman güvenilir biçimde okunur.
        let lines = text.contains("-->") ? cueLines(text) : plainLines(text, userName: userName)
        return segments(from: lines, userName: userName)
    }

    /// Ayrıştırıcının ara ürünü: bir replik.
    struct Line: Equatable {
        var speaker: String?
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
    }

    // MARK: - Ortak

    /// Satır sonları, BOM ve bölünemez boşluk. Windows'tan gelen dosya
    /// `\r\n` taşır ve `\r` metnin sonuna yapışıp konuşmacı adını bozar.
    static func normalized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// `01:02:03.400`, `02:03,400`, `2:03` → saniye.
    static func seconds(_ token: String) -> TimeInterval? {
        let cleaned = token.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || $0 == "." }),
                  let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: - Altyazı biçimi (VTT / SRT)

    /// Blok ayırıcı boş satıra **güvenilmez**: dışa aktarımların bir kısmı
    /// blokları boş satırsız yazıyor. Sınır, zaman satırının kendisidir.
    static func cueLines(_ text: String) -> [Line] {
        var result: [Line] = []
        var current: Line?
        /// Sıra numarası zaman satırından **önce** gelir; hemen ardından zaman
        /// satırı gelmezse gerçek bir metindir ve atılmaz.
        var pendingNumber: String?

        func flush() {
            if let line = current, !line.text.isEmpty { result.append(line) }
            current = nil
        }

        for row in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)

            if let range = trimmed.range(of: "-->") {
                pendingNumber = nil
                flush()
                let startToken = String(trimmed[..<range.lowerBound])
                // Bitiş damgasının ardında hizalama ayarları olabilir
                // ("00:00:04.000 align:start position:0%").
                let endToken = String(trimmed[range.upperBound...])
                    .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                guard let start = seconds(startToken), let end = seconds(endToken) else { continue }
                current = Line(speaker: nil, text: "", start: start, end: max(end, start))
                continue
            }

            if trimmed.isEmpty {
                // Tutulan sayı sıra numarası değilmiş: metnin kendisiymiş.
                if let held = pendingNumber { append(held, to: &current); pendingNumber = nil }
                flush()
                continue
            }
            if trimmed == "WEBVTT" || trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE")
                || trimmed.hasPrefix("X-TIMESTAMP") { continue }
            if trimmed.allSatisfy(\.isNumber) {
                // Numara olabilir; kararı bir sonraki satır verir.
                if let held = pendingNumber { append(held, to: &current) }
                pendingNumber = trimmed
                continue
            }
            if let held = pendingNumber { append(held, to: &current); pendingNumber = nil }
            append(trimmed, to: &current)
        }
        if let held = pendingNumber { append(held, to: &current) }
        flush()

        return result.map { line in
            var line = line
            let (speaker, body) = payload(line.text)
            line.speaker = speaker
            line.text = body
            return line
        }
        .filter { !$0.text.isEmpty }
    }

    private static func append(_ text: String, to line: inout Line?) {
        guard line != nil else { return }
        line!.text += line!.text.isEmpty ? text : " " + text
    }

    /// `<v Ayşe>merhaba</v>`, `Ayşe: merhaba` ya da düz metin.
    static func payload(_ raw: String) -> (speaker: String?, text: String) {
        var text = raw
        var speaker: String?

        // WebVTT konuşmacı etiketi. Teams dökümü bunu kullanıyor.
        if let open = text.range(of: "<v "), let close = text[open.upperBound...].firstIndex(of: ">") {
            let name = String(text[open.upperBound..<close]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { speaker = name }
            text.removeSubrange(open.lowerBound...close)
        }
        // Kalan biçim etiketleri (`</v>`, `<i>`, `<c.colorE5E5E5>`).
        text = stripTags(text).trimmingCharacters(in: .whitespaces)

        if speaker == nil, let candidate = speakerCandidate(in: text) {
            speaker = candidate.name
            text = candidate.rest
        }
        return (speaker, text)
    }

    static func stripTags(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "<" { depth += 1; continue }
            if character == ">" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(character) }
        }
        return out
    }

    // MARK: - Düz metin

    static func plainLines(_ text: String, userName: String = "") -> [Line] {
        var candidates: [String: Int] = [:]
        var rows: [(time: TimeInterval?, candidate: (name: String, rest: String)?, text: String)] = []

        for row in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = stripMarkers(String(row))
            guard !stripped.isEmpty else { continue }
            let (time, rest) = leadingTime(stripped)
            guard !rest.isEmpty else { continue }
            let candidate = speakerCandidate(in: rest)
            if let candidate {
                candidates[candidate.name, default: 0] += 1
            }
            rows.append((time, candidate, rest))
        }

        // Bir ad, ancak **birden çok satırın başında** görünüyorsa konuşmacıdır.
        //
        // Tek geçen önek reddedilir: "Not: bunu unutma", "Karar: bütçe onaylandı"
        // satırlarındaki etiket konuşmacı sanılırsa hem uydurma bir kişi
        // eklenir hem de metnin başı kesilir. Reddedilen önek **metinde
        // kalır** — kaybolan bir şey yok, yalnızca atfedilmemiş bir satır
        // olur; kendinden emin yanlış bir ad boş bir alandan kötüdür.
        //
        // Kullanıcının kendi adı ve "Ben" tek geçişte de kabul edilir: onlar
        // tahmin değil, ayarlardan bilinen bir gerçek.
        let accepted = Set(candidates.filter { $0.value >= 2 }.keys)

        return rows.map { row in
            if let candidate = row.candidate,
               accepted.contains(candidate.name) || isSelfName(candidate.name, userName: userName) {
                return Line(speaker: candidate.name, text: candidate.rest,
                            start: row.time, end: nil)
            }
            return Line(speaker: nil, text: row.text, start: row.time, end: nil)
        }
    }

    /// Markdown ve döküm işaretleri: `#`, `>`, `-`, `*`, `•`.
    static func stripMarkers(_ row: String) -> String {
        var text = row.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#>-*•–—".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// `[00:12:34] …`, `(12:34) …`, `00:12:34 …` → (saniye, kalan).
    static func leadingTime(_ row: String) -> (TimeInterval?, String) {
        if let first = row.first, first == "[" || first == "(" {
            let closing: Character = first == "[" ? "]" : ")"
            if let end = row.firstIndex(of: closing) {
                let inside = String(row[row.index(after: row.startIndex)..<end])
                if let time = seconds(inside) {
                    let rest = String(row[row.index(after: end)...])
                    return (time, stripMarkers(rest))
                }
            }
            return (nil, row)
        }
        guard let token = row.split(whereSeparator: \.isWhitespace).first.map(String.init),
              token.contains(":"), let time = seconds(token) else { return (nil, row) }
        let rest = String(row.dropFirst(token.count))
        return (time, stripMarkers(rest))
    }

    /// `Ayşe Yılmaz: merhaba` → ("Ayşe Yılmaz", "merhaba").
    ///
    /// Ad gibi durmayan hiçbir şey kabul edilmez: cümle noktalaması taşıyan,
    /// dört kelimeden uzun ya da 40 karakteri geçen bir önek konuşmacı değildir.
    static func speakerCandidate(in row: String) -> (name: String, rest: String)? {
        guard let colon = row.firstIndex(of: ":") else { return nil }
        let name = String(row[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = String(row[row.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !rest.isEmpty, name.count <= 40,
              name.split(whereSeparator: \.isWhitespace).count <= 4,
              !name.contains(where: { ".!?,;\"".contains($0) })
        else { return nil }
        // "12:34 kadar" gibi saat parçalarını ad sanma.
        guard !name.allSatisfy({ $0.isNumber }) else { return nil }
        return (name, rest)
    }

    // MARK: - Segmentler

    static func segments(from lines: [Line], userName: String) -> [Segment] {
        var result: [Segment] = []
        var cursor: TimeInterval = 0

        for line in lines.flatMap(split(_:)) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Damga varsa ona uyulur; yoksa konuşma hızından uydurulur. İki
            // durumda da **kesin olarak artar**: eşit `start` iki satırı
            // birbirinin yerine geçirilebilir kılıyor (bkz. tip yorumu, 1).
            let start = max(line.start ?? cursor, cursor)
            let spoken = max(Self.minimumLineDuration,
                             Double(text.count) / Self.charactersPerSecond)
            let end = max(line.end ?? (start + spoken), start + 0.1)
            cursor = end + 0.01

            let speaker = line.speaker?.trimmingCharacters(in: .whitespaces)
            let channel: Channel = isSelfName(speaker, userName: userName) ? .mic : .system
            let label = speaker.flatMap { $0.isEmpty ? nil : $0 } ?? channel.speaker
            result.append(Segment(channel: channel, speaker: label, text: text,
                                  start: start, end: end, confidence: nil, words: []))
        }
        return result
    }

    /// Uzun satırı cümle sınırından böler; damgası varsa süreyi karakter
    /// sayısına göre paylaştırır.
    static func split(_ line: Line) -> [Line] {
        guard line.text.count > Self.lineLimit else { return [line] }
        let pieces = sentencePieces(line.text, limit: Self.lineLimit)
        guard pieces.count > 1 else { return [line] }

        guard let start = line.start, let end = line.end, end > start else {
            return pieces.map { Line(speaker: line.speaker, text: $0, start: nil, end: nil) }
        }
        let total = Double(pieces.reduce(0) { $0 + $1.count })
        var cursor = start
        return pieces.map { piece in
            let share = (end - start) * Double(piece.count) / max(total, 1)
            let pieceStart = cursor
            cursor += share
            return Line(speaker: line.speaker, text: piece, start: pieceStart, end: cursor)
        }
    }

    /// Metni `limit`i aşmayan, cümle sınırlarında biten parçalara böler.
    /// Tek bir cümle sınırı aşıyorsa (noktalamasız ham metin) kelimeden bölünür.
    static func sentencePieces(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }

        for sentence in sentenceUnits(text) {
            for unit in sentence.count > limit ? wordPieces(sentence, limit: limit) : [sentence] {
                if !current.isEmpty, current.count + 1 + unit.count > limit { flush() }
                current += current.isEmpty ? unit : " " + unit
            }
        }
        flush()
        return pieces
    }

    /// Cümle sonu: `.!?…` ve ardından boşluk.
    static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let last = previous, ".!?…".contains(last) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { units.append(trimmed) }
                current = ""
                previous = nil
                continue
            }
            current.append(character)
            previous = character
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { units.append(trimmed) }
        return units
    }

    static func wordPieces(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !current.isEmpty, current.count + 1 + word.count > limit {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - Kimlik

    /// Bu ad kaydı tutan kişinin mi? Karşılaştırma Türkçe locale ile yapılır —
    /// `I`/`İ` ayrımı.
    static func isSelfName(_ name: String?, userName: String = "") -> Bool {
        guard let name else { return false }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        guard !key.isEmpty else { return false }
        if selfNames.contains(key) { return true }
        let mine = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        return !mine.isEmpty && key == mine
    }
}
