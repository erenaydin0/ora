// Faz 4 probe: uygulamadaki noktalama + map-reduce mantığının aynısı,
// gerçek uzunlukta (60 dk mertebesi) Türkçe transkript üzerinde.
import Foundation
import FoundationModels

@Generable
struct Ozet {
    @Guide(description: "Toplantının 2-3 cümlelik Türkçe özeti") var genelBakis: String
    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6)) var kararlar: [String]
    @Generable struct Aksiyon {
        @Guide(description: "Sorumlu kişinin adı, belli değilse 'belirtilmedi'") var kisi: String
        @Guide(description: "Yapılacak iş") var gorev: String
        @Guide(description: "Son tarih, belirtilmemişse 'belirtilmedi'") var sonTarih: String
    }
    @Guide(description: "Aksiyon maddeleri", .maximumCount(8)) var aksiyonlar: [Aksiyon]
}

let instructions = "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver."

func normalized(_ s: String) -> String {
    s.lowercased(with: Locale(identifier: "tr_TR")).unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}
func numberedLines(_ r: String) -> [String] {
    r.split(separator: "\n").map { line -> String in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let d = t.firstIndex(of: "."), t[t.startIndex..<d].allSatisfy(\.isNumber), d < t.endIndex
        else { return t }
        return String(t[t.index(after: d)...]).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
}

// --- Girdi: noktalamasız Türkçe replikler (Speech API'nin gerçek çıktı biçimi) ---
let replikler = [
    "Ben: toplantıya başlamadan önce geçen haftaki aksiyonları gözden geçirelim",
    "Katılımcı: entegrasyon testlerinin yüzde sekseni bitti kalanı cuma gününe kadar tamamlarım",
    "Katılımcı: şirket içi güvenlik denetimi çarşamba gününe ertelendi bütçe onayını perşembeye kadar ileteceğim",
    "Ben: yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri bildirimleri değerlendirilecek",
    "Katılımcı: anlaşıldı ben de test raporunu pazartesi paylaşırım",
    "Ben: veri tabanı göçü için ayrı bir bakım penceresi açmamız gerekiyor cumartesi gecesi uygun mu",
    "Katılımcı: cumartesi gecesi olur ama yedekleme süresini de hesaba katmalıyız yaklaşık iki saat sürüyor",
    "Ben: müşteri tarafındaki entegrasyon dokümanını kim güncelleyecek",
    "Katılımcı: ben üstlenirim önümüzdeki salıya kadar taslağı çıkarırım",
    "Ben: işe alım sürecinde iki aday final aşamasında referans kontrolleri bu hafta tamamlanacak",
]

@main struct M {
  static func main() async {
    switch SystemLanguageModel.default.availability {
    case .available: print("model: available")
    case .unavailable(let r): print("model kullanılamıyor: \(r)"); return
    }
    let clock = ContinuousClock()

    // === 1. Noktalama restorasyonu + kelime koruma güvencesi ===
    print("\n=== NOKTALAMA ===")
    let chunk = Array(replikler.prefix(5))
    let numbered = chunk.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let t0 = clock.now
    let s = LanguageModelSession(instructions: instructions)
    do {
        let r = try await s.respond(to: """
            Aşağıdaki numaralı satırlara noktalama işaretleri ve büyük harf düzeltmesi ekle.
            Kuralar:
            - Kelimeleri DEĞİŞTİRME, EKLEME veya SİLME. Yalnızca noktalama ve büyük/küçük harf.
            - Satır sayısını ve numaralandırmayı aynen koru.
            - Yorum, açıklama veya başlık ekleme.

            \(numbered)
            """)
        let lines = numberedLines(r.content)
        print("süre \(clock.now - t0) · satır \(lines.count)/\(chunk.count)")
        var kept = 0, rejected = 0
        for (orig, line) in zip(chunk, lines) {
            let ok = normalized(orig) == normalized(line)
            ok ? (kept += 1) : (rejected += 1)
            print("  \(ok ? "✓" : "✗ REDDEDİLDİ") \(line)")
            if !ok { print("      orijinal: \(orig)") }
        }
        print("kabul \(kept) · reddedilen \(rejected)")
    } catch { print("noktalama hatası: \(error)") }

    // === 2. Map-reduce — 60 dk mertebesinde transkript ===
    print("\n=== MAP-REDUCE ===")
    var uzun: [String] = []
    for tur in 1...12 { for r in replikler { uzun.append(r.replacingOccurrences(of: "Ben:", with: "Ben:") + " (tur \(tur))") } }
    let tamMetin = uzun.joined(separator: "\n")
    print("transkript: \(tamMetin.count) karakter ≈ \(tamMetin.count/4) token")

    // parçalama — uygulamadaki ile aynı sınır
    let limit = 10_000
    var parcalar: [String] = []; var cur = ""
    for line in uzun {
        if !cur.isEmpty && cur.count + line.count + 1 > limit { parcalar.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : "\n") + line
    }
    if !cur.isEmpty { parcalar.append(cur) }
    print("parça sayısı: \(parcalar.count) (en büyük \(parcalar.map(\.count).max() ?? 0) karakter)")

    let mapStart = clock.now
    var kismi: [String] = []
    var basliklar: [String] = []
    for (i, p) in parcalar.enumerated() {
        let ss = LanguageModelSession(instructions: instructions)   // her parça için YENİ oturum
        do {
            let r = try await ss.respond(to: """
                Bu toplantı bölümünü Türkçe olarak özetle. Kararları ve kimin neyi
                üstlendiğini mutlaka koru. En fazla 6 cümle.

                \(p)
                """)
            kismi.append(r.content)
            print("  parça \(i+1)/\(parcalar.count) ✓ (\(p.count) karakter → \(r.content.count))")
        } catch { print("  parça \(i+1) ✗ \(error)"); kismi.append(String(p.prefix(600))) }

        let ts = LanguageModelSession(instructions: instructions)
        if let r = try? await ts.respond(to: "Bu toplantı bölümüne 2-5 kelimelik Türkçe bir başlık ver:\n\n\(p)") {
            basliklar.append(r.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    print("map süresi: \(clock.now - mapStart)")

    let birlesik = kismi.joined(separator: "\n")
    print("kısmi özetler toplamı: \(birlesik.count) karakter")

    let reduceStart = clock.now
    let rs = LanguageModelSession(instructions: instructions)
    do {
        let r = try await rs.respond(to: """
            Aşağıda bir toplantının bölüm bölüm özetleri var. Bunları birleştirerek
            toplantının genel özetini, alınan kararları ve aksiyon maddelerini çıkar.

            \(birlesik)
            """, generating: Ozet.self)
        print("reduce süresi: \(clock.now - reduceStart)")
        let o = r.content
        print("\nGENEL BAKIŞ: \(o.genelBakis)")
        print("\nKARARLAR:"); o.kararlar.forEach { print("  • \($0)") }
        print("\nAKSİYONLAR:"); o.aksiyonlar.forEach { print("  • \($0.kisi) → \($0.gorev) [\($0.sonTarih)]") }
        print("\nKONU BAŞLIKLARI:"); basliklar.forEach { print("  • \($0)") }
        print("\nTOPLAM: \(clock.now - mapStart)")
    } catch { print("❌ reduce hatası: \(error)") }
  }
}
