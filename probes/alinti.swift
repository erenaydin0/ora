// Faz 8 probe: özet maddesi → transkript eşleştirmesi (alıntı bağı) gerçek
// veride ne kadar tutuyor?
//
// Soru şu: kelime örtüşmesi ölçütüyle bir aksiyonun/kararın transkriptteki
// yerini bulabiliyor muyuz, ve bulduğumuz yer doğru mu? Eşik 0,5.
// Eşik altında madde tıklanabilir olmuyor — yanlış yere atlamak, hiç
// atlamamaktan kötü.
//
// Çalıştırma: swift probes/alinti.swift [veritabanı yolu]
import Foundation

let defaultPath = NSHomeDirectory()
    + "/Library/Containers/com.orameetings.ora/Data/Library/Application Support/ora/ora.sqlite"
let dbPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath

/// sqlite3 CLI ile JSON okuma — probe'un GRDB'ye ihtiyacı olmasın.
func query(_ sql: String) -> [[String: Any]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [dbPath, "-json", sql]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
}

/// FoundationIntelligence.words(of:) ile **birebir** aynı: Türkçe küçük harf,
/// diakritik düşürme, 2 harften uzun kelimeler, kaba gövdeleme (ilk 5 harf).
func words(of text: String) -> [String] {
    text.lowercased(with: Locale(identifier: "tr_TR"))
        .split { !$0.isLetter && !$0.isNumber }
        .map { String($0.folding(options: .diacriticInsensitive,
                                 locale: Locale(identifier: "tr_TR"))) }
        .filter { $0.count > 2 }
        .map { String($0.prefix(5)) }
}

struct Line { let start: Double; let text: String; let words: Set<String> }

/// Kelime ağırlığı: bir kelime kaç segmentte geçiyorsa o kadar değersizdir
/// (IDF). Düz örtüşme sayımı "yapmak", "olarak", "belirlemek" gibi her yerde
/// geçen kelimeleri kanıt sayıyor ve yanlış yere atlıyordu — ölçüldü.
func weights(_ lines: [Line]) -> [String: Double] {
    var df: [String: Int] = [:]
    for line in lines { for word in line.words { df[word, default: 0] += 1 } }
    let total = Double(max(lines.count, 2))
    return df.mapValues { max(0, log(total / Double(1 + $0))) }
}

/// Segment.bestMatch ile aynı hesap: ağırlıklı örtüşme oranı.
func bestMatch(_ text: String, _ lines: [Line], _ weight: [String: Double],
               threshold: Double) -> (line: Line, score: Double, hits: [String])? {
    let needle = Set(words(of: text))
    guard needle.count >= 3 else { return nil }
    // Transkriptte hiç geçmeyen kelime kanıt da olamaz, gürültü de:
    // toplam ağırlık yalnızca **geçen** kelimelerden kurulur.
    let total = needle.reduce(0.0) { $0 + (weight[$1] ?? 0) }
    guard total > 0 else { return nil }
    var best: (Line, Double)?
    for line in lines where !line.words.isEmpty {
        let hit = needle.intersection(line.words).reduce(0.0) { $0 + (weight[$1] ?? 0) }
        let score = hit / total
        if score > (best?.1 ?? 0) { best = (line, score) }
    }
    guard let best, best.1 >= threshold else { return nil }
    let hits = needle.intersection(best.0.words)
        .sorted { (weight[$0] ?? 0) > (weight[$1] ?? 0) }
        .map { "\($0)(\(String(format: "%.1f", weight[$0] ?? 0)))" }
    return (best.0, best.1, hits)
}

func timeLabel(_ seconds: Double) -> String {
    String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

let meetings = query("SELECT id, title FROM meetings ORDER BY id")
guard !meetings.isEmpty else { print("✗ toplantı yok: \(dbPath)"); exit(1) }

var totals = (items: 0, matched: 0)
for meeting in meetings {
    guard let id = meeting["id"] as? Int else { continue }
    let title = meeting["title"] as? String ?? "?"
    let lines = query("SELECT start_time, text FROM transcripts WHERE meeting_id = \(id) ORDER BY start_time")
        .compactMap { row -> Line? in
            guard let text = row["text"] as? String else { return nil }
            let start = (row["start_time"] as? Double) ?? Double(row["start_time"] as? Int ?? 0)
            return Line(start: start, text: text, words: Set(words(of: text)))
        }
    guard !lines.isEmpty else { continue }

    var items: [(kind: String, text: String)] = []
    for row in query("SELECT task FROM action_items WHERE meeting_id = \(id)") {
        if let task = row["task"] as? String { items.append(("aksiyon", task)) }
    }
    for row in query("SELECT overview, decisions FROM summaries WHERE meeting_id = \(id)") {
        for key in ["overview", "decisions"] {
            guard let json = row[key] as? String, let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { continue }
            let kind = key == "overview" ? "genel bakış" : "karar"
            items.append(contentsOf: list.map { (kind, $0) })
        }
    }
    for row in query("SELECT bullets FROM topic_segments WHERE meeting_id = \(id)") {
        guard let json = row["bullets"] as? String, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { continue }
        items.append(contentsOf: list.map { ("konu maddesi", $0) })
    }
    guard !items.isEmpty else { continue }

    let weight = weights(lines)
    // Eşik taraması — sayı seçilirken tahmin yürütülmesin.
    let sweep = [0.3, 0.4, 0.5, 0.6, 0.7].map { threshold -> String in
        let hits = items.filter { bestMatch($0.text, lines, weight, threshold: threshold) != nil }.count
        return "\(threshold): \(hits)/\(items.count)"
    }
    print("\neşik taraması — \(sweep.joined(separator: "  "))")

    var matched = 0
    var examples: [String] = []
    for item in items {
        if let hit = bestMatch(item.text, lines, weight, threshold: 0.5) {
            matched += 1
            if examples.count < 3 {
                examples.append("  ✓ \(item.kind) · skor \(String(format: "%.2f", hit.score)) "
                    + "→ \(timeLabel(hit.line.start))\n     madde: \(item.text.prefix(70))"
                    + "\n     kanıt: \(hit.hits.prefix(6).joined(separator: " "))")
            }
        } else if examples.count < 4 {
            examples.append("  – eşleşmedi: \(item.text.prefix(70))")
        }
    }
    totals.items += items.count
    totals.matched += matched
    let rate = Double(matched) / Double(items.count) * 100
    print("\n\(title) — \(lines.count) segment, \(items.count) madde, "
          + "\(matched) eşleşti (%\(Int(rate.rounded())))")
    print(examples.joined(separator: "\n"))
}

print("\n— toplam —")
print("\(totals.matched)/\(totals.items) madde transkriptte bir yere bağlandı "
      + "(%\(Int((Double(totals.matched) / Double(max(totals.items, 1)) * 100).rounded())))")
print("Bağlanamayan maddeler tıklanabilir olmaz; yanlış yere atlamaktan iyidir.")
