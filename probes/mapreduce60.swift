// Faz 4 probe: 60 dakikalık toplantı mertebesinde map-reduce (~50.000 karakter).
// Ayrıca @Generable konu başlığı şemasının tek satır ürettiğini doğrular.
import Foundation
import FoundationModels

@Generable struct Ozet {
    @Guide(description: "Toplantının 2-3 cümlelik Türkçe özeti") var genelBakis: String
    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6)) var kararlar: [String]
    @Generable struct Aksiyon {
        @Guide(description: "Sorumlu kişinin adı, belli değilse 'belirtilmedi'") var kisi: String
        @Guide(description: "Yapılacak iş") var gorev: String
        @Guide(description: "Son tarih, belirtilmemişse 'belirtilmedi'") var sonTarih: String
    }
    @Guide(description: "Aksiyon maddeleri", .maximumCount(8)) var aksiyonlar: [Aksiyon]
}
@Generable struct KonuBasligi {
    @Guide(description: "Bu bölümün 2-5 kelimelik Türkçe başlığı") var baslik: String
}

let ins = "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver."

let konular: [[String]] = [
    ["Ben: Ayşe entegrasyon testlerinin durumu ne oldu",
     "Katılımcı: Yüzde seksen tamamlandı, kalan kısmı cuma gününe kadar bitiririm",
     "Ben: Test raporunu da paylaşabilir misin",
     "Katılımcı: Pazartesi sabahı paylaşırım"],
    ["Ben: Güvenlik denetimi hangi tarihe alındı",
     "Katılımcı: Mehmet çarşambaya erteledi, dış denetçi o gün müsait",
     "Ben: Bütçe onayı ne durumda",
     "Katılımcı: Mehmet perşembeye kadar iletecek"],
    ["Ben: Veri tabanı göçü için bakım penceresi lazım",
     "Katılımcı: Cumartesi gecesi uygun, yedekleme iki saat sürüyor",
     "Ben: O halde gece bir sularında başlayalım",
     "Katılımcı: Kerem operasyon tarafını üstlenir"],
    ["Ben: Müşteri entegrasyon dokümanı güncellenmeli",
     "Katılımcı: Ben üstlenirim, salıya kadar taslağı çıkarırım",
     "Ben: Sürüm notlarını da ekleyelim",
     "Katılımcı: Eklerim, gözden geçirmeyi Zeynep yapsın"],
    ["Ben: İşe alımda iki aday final aşamasında",
     "Katılımcı: Referans kontrolleri bu hafta tamamlanıyor",
     "Ben: Teklif hazırlığını kim yapacak",
     "Katılımcı: Zeynep insan kaynaklarıyla birlikte hazırlayacak"],
]

@main struct M { static func main() async {
    guard case .available = SystemLanguageModel.default.availability else {
        print("model kullanılamıyor"); return }
    let clock = ContinuousClock()

    var satirlar: [String] = []
    var tur = 0
    while satirlar.joined(separator: "\n").count < 50_000 {
        tur += 1
        for blok in konular { for s in blok { satirlar.append(s) } }
    }
    let tam = satirlar.joined(separator: "\n")
    print("transkript: \(tam.count) karakter ≈ \(tam.count/4) token · \(satirlar.count) replik")
    print("(60 dakikalık bir toplantı mertebesi)")

    let limit = 10_000
    var parcalar: [String] = []; var cur = ""
    for line in satirlar {
        if !cur.isEmpty && cur.count + line.count + 1 > limit { parcalar.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : "\n") + line
    }
    if !cur.isEmpty { parcalar.append(cur) }
    print("parça: \(parcalar.count) · en büyük \(parcalar.map(\.count).max() ?? 0) karakter\n")

    let t0 = clock.now
    var kismi: [String] = []; var basliklar: [String] = []
    var guardrail = 0
    for (i, p) in parcalar.enumerated() {
        let s = LanguageModelSession(instructions: ins)
        do {
            let r = try await s.respond(to: """
                Bu toplantı bölümünü Türkçe olarak özetle. Kararları ve kimin neyi
                üstlendiğini mutlaka koru. Konuşmada geçen kişi adlarını aynen kullan.
                "Ben" bu kaydı tutan kişidir. En fazla 6 cümle.

                \(p)
                """)
            kismi.append(r.content)
            print("  parça \(i+1)/\(parcalar.count) ✓")
        } catch let e as LanguageModelSession.GenerationError {
            if case .guardrailViolation = e { guardrail += 1 }
            print("  parça \(i+1) ✗ \(e)"); kismi.append(String(p.prefix(600)))
        } catch { print("  parça \(i+1) ✗"); kismi.append(String(p.prefix(600))) }

        let ts = LanguageModelSession(instructions: ins)
        if let r = try? await ts.respond(
            to: "Bu toplantı bölümüne 2-5 kelimelik Türkçe bir başlık ver:\n\n\(p)",
            generating: KonuBasligi.self) {
            basliklar.append(r.content.baslik)
        }
    }
    let mapSure = clock.now - t0
    var birlesik = kismi.joined(separator: "\n")
    print("\nmap süresi: \(mapSure) · kısmi özet toplamı \(birlesik.count) karakter")

    var tur2 = 0
    while birlesik.count > limit && tur2 < 4 {
        tur2 += 1
        var next: [String] = []
        var buf = ""
        for line in birlesik.split(separator: "\n", omittingEmptySubsequences: false) {
            if buf.count + line.count + 1 > limit && !buf.isEmpty { next.append(buf); buf = "" }
            buf += (buf.isEmpty ? "" : "\n") + line
        }
        if !buf.isEmpty { next.append(buf) }
        var out: [String] = []
        for piece in next {
            let s = LanguageModelSession(instructions: ins)
            if let r = try? await s.respond(to: "Bu özetleri Türkçe olarak birleştir, en fazla 6 cümle:\n\n\(piece)") {
                out.append(r.content)
            } else { out.append(String(piece.prefix(600))) }
        }
        birlesik = out.joined(separator: "\n")
        print("ek indirgeme turu \(tur2) → \(birlesik.count) karakter")
    }

    let rs = LanguageModelSession(instructions: ins)
    do {
        let r = try await rs.respond(to: """
            Aşağıda bir toplantının bölüm bölüm özetleri var. Bunları birleştirerek
            toplantının genel özetini, alınan kararları ve aksiyon maddelerini çıkar.
            Aksiyonlarda sorumlu kişi olarak metinde geçen adı yaz; kaydı tutan
            kişi için "Ben" yaz.

            \(birlesik)
            """, generating: Ozet.self)
        let o = r.content
        print("\n=== SONUÇ · toplam \(clock.now - t0) · guardrail \(guardrail) ===")
        print("\nGENEL BAKIŞ: \(o.genelBakis)")
        print("\nKARARLAR:"); o.kararlar.forEach { print("  • \($0)") }
        print("\nAKSİYONLAR:"); o.aksiyonlar.forEach { print("  • \($0.kisi) → \($0.gorev) [\($0.sonTarih)]") }
        print("\nKONU BAŞLIKLARI (\(basliklar.count)):"); basliklar.prefix(8).forEach { print("  • \($0)") }
    } catch { print("❌ reduce: \(error)") }
} }
