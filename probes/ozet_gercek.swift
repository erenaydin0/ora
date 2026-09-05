// Circleback referanslı özet hattının ölçümü — gerçekçi bir Türkçe toplantı.
//
// Üç kip:
//   ROSTER=0|1  kapalı katılımcı listesinin isteme yazılıp yazılmadığı (A/B)
//   SCALE=N     transkripti N kez tekrarlar; N büyükse 60 dakikalık mertebe
//   GUARDRAIL=1 parça istemini 8 kez koşup guardrail oranını ölçer
//               (RESEARCH.md §15.1 yöntemi)
//
// Taban (RESEARCH.md §15.2, eski iki-çağrılı hat): map 47,9 sn · toplam 55,3 sn.
//
// Referans hedefleri (`circleback-notes/` ölçümü):
//   bölüm 5-7 · bölüm başına madde 2-9 · genel bakış 4-6 · aksiyon 2-5
//   madde uzunluğu medyan ~134 karakter
import Foundation
import FoundationModels

@Generable struct ToplantiOzeti {
    @Guide(description: "Toplantının en önemli sonuçları; her madde tek cümle",
           .maximumCount(6)) var genelBakis: [String]
    @Guide(description: "Toplantıda alınan kararlar", .maximumCount(6)) var kararlar: [String]
}
enum Ozet {
    @Generable struct Aksiyon {
        @Guide(description: "Sorumlu kişinin adı, belli değilse 'belirtilmedi'") var kisi: String
        @Guide(description: "Yapılacak iş, emir kipiyle ve kısa. Yalnızca "
               + "henüz yapılmamış işler; tamamlanmış işler aksiyon değildir") var gorev: String
        @Guide(description: "Bu işin toplantıda hangi konuşmadan çıktığını "
               + "anlatan tam bir cümle") var baglam: String
        @Guide(description: "Son tarih, belirtilmemişse 'belirtilmedi'") var sonTarih: String
    }
}
@Generable struct KonuBlogu {
    @Guide(description: "Bu konunun 2-6 kelimelik Türkçe başlığı") var baslik: String
    @Guide(description: "Bu konuda konuşulanlar. Her madde tek cümle ama iki "
           + "bölümlü olsun: önce ne olduğu, sonra sonucu ya da kimin ne "
           + "yapacağı", .maximumCount(8)) var maddeler: [String]
}
@Generable struct Baslik {
    @Guide(description: "3-6 kelimelik Türkçe başlık") var b: String
}

@Generable struct ParcaOzeti {
    @Guide(description: "Bu bölümde ele alınan ayrı konular", .maximumCount(4))
    var konular: [KonuBlogu]
    @Guide(description: "Bu bölümde birinin açıkça üstlendiği işler; "
           + "kimse üstlenmediyse boş", .maximumCount(4)) var aksiyonlar: [Ozet.Aksiyon]
}

let ins = """
    Sen bir toplantı asistanısın. Türkçe toplantıda Türkçe yanıt ver.
    Yalnızca metinde geçen bilgiyi kullan; çıkarım yapma, uydurma.
    Sayıları, tarihleri ve özel isimleri aynen koru.
    """
let tarih = "Toplantı tarihi: Salı, 18 Ağustos 2026. "
    + "Metinde geçen gün adlarını bu tarihe göre yorumla; tarih uydurma."
let rosterAcik = ProcessInfo.processInfo.environment["ROSTER"] != "0"
let roster = ["Eren AYDIN", "Zerrin ALTUN"]
let rosterSatiri = rosterAcik
    ? "- Sorumlu kişi alanına yalnızca şu adlardan biri yazılabilir: "
      + roster.joined(separator: ", ")
      + ". Bu listede olmayan biri için \"belirtilmedi\" yaz.\n"
    : ""

func parcaIstemi(_ metin: String, hedef: Int) -> String {
    """
                Bu toplantı bölümünü konularına ayır. En fazla \(hedef) konu çıkar.
                Her konu için 2-6 kelimelik bir başlık ve o konuda konuşulanları
                anlatan maddeler yaz. Az konu isteniyorsa her konuyu daha ayrıntılı
                yaz; konuşulan her önemli noktaya bir madde ayır.
                Kurallar:
                - Her madde tek cümle olsun ve tek başına anlaşılsın.
                - Sayıları, tarihleri, firma ve kişi adlarını metinde geçtiği gibi yaz.
                - "Toplantıda konuşuldu" gibi dolgu cümle kurma; ne olduğunu yaz.
                - Kim ne üstlendiyse adıyla yaz. "Ben" bu kaydı tutan kişidir, adı Eren AYDIN.
                - "Ben", "Katılımcı" gibi konuşmacı etiketlerini maddeye yazma.
                Aksiyon kuralları:
                - Yalnızca birinin **açıkça üstlendiği** işleri yaz. Durum bildiren
                  cümleleri ("şu çalışıyor", "şu tamamlandı") aksiyon sayma.
                - Sorumluyu metinde o işi üstlenen kişiden al; anlaşılmıyorsa
                  "belirtilmedi" yaz.
                - Yapılmış işleri değil, **yapılacak** işleri yaz.
                - Bağlam alanına işin hangi konuşmadan çıktığını yaz.
                - Son tarihi yalnızca metinde açıkça geçiyorsa yaz.
                \(rosterSatiri)\(tarih)

                \(metin)
                """
}

func kelimeler(_ t: String) -> [String] {
    t.lowercased(with: Locale(identifier: "tr_TR"))
        .split { !$0.isLetter && !$0.isNumber }
        .map { String($0.folding(options: .diacriticInsensitive,
                                 locale: Locale(identifier: "tr_TR"))) }
        .filter { $0.count > 2 }
}
func norm(_ t: String) -> String { kelimeler(t).joined() }

/// FoundationIntelligence.validated() ile aynı kurallar.
let narrationVerbs: Set<String> = [
    "belirtti", "soyledi", "dedi", "anlatti", "gosterdi", "aktardi",
    "vurguladi", "hatirlatti", "sordu", "acikladi", "ekledi", "yanitladi",
]
let pastEndings = ["di", "dı", "du", "dü", "ti", "tı", "tu", "tü"]
func durumCumlesiMi(_ gorev: String) -> Bool {
    guard let last = kelimeler(gorev).last else { return true }
    if last.hasSuffix("yor") || last.hasSuffix("yorlar") { return true }
    return pastEndings.contains { last.hasSuffix($0) }
}

func dogrula(_ a: Ozet.Aksiyon, basliklar: [String]) -> Ozet.Aksiyon {
    var r = a
    let key = norm(a.kisi)
    if key == norm("Ben") { r.kisi = "Eren AYDIN" }
    else if key == norm("Katılımcı") || key.isEmpty { r.kisi = "belirtilmedi" }

    let filler: Set<String> = ["konusundan", "konusunda", "cikti", "cikan",
                               "hakkinda", "ile", "bu", "icin"]
    let w = Set(kelimeler(a.baglam)).subtracting(filler)
    let echo = w.isEmpty || basliklar.contains { b in
        let bw = Set(kelimeler(b))
        return !bw.isEmpty && Double(w.intersection(bw).count) / Double(w.count) >= 0.6
    }
    if echo || a.baglam.split(separator: " ").count < 4 { r.baglam = "" }

    if norm(a.sonTarih).contains(norm("18 Ağustos 2026")) { r.sonTarih = "belirtilmedi" }
    return r
}

func medyan(_ xs: [Int]) -> Int {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); return s[s.count / 2]
}

@main struct M { static func main() async {
    guard case .available = SystemLanguageModel.default.availability else {
        print("model kullanılamıyor"); return }
    let dosya = ProcessInfo.processInfo.environment["FILE"] ?? "gercek_toplanti.txt"
    let url = URL(fileURLWithPath: dosya)
    guard let metin = try? String(contentsOf: url, encoding: .utf8) else {
        print("\(dosya) okunamadı"); return }

    let kez = Int(ProcessInfo.processInfo.environment["SCALE"] ?? "1") ?? 1
    let birim = metin.split(separator: "\n").map(String.init)
    var satirlar: [String] = []
    for _ in 0 ..< max(1, kez) { satirlar.append(contentsOf: birim) }
    let limit = 6_000
    var parcalar: [String] = []; var cur = ""
    for line in satirlar {
        if !cur.isEmpty && cur.count + line.count + 1 > limit { parcalar.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : "\n") + line
    }
    if !cur.isEmpty { parcalar.append(cur) }
    let hedef = max(1, min(4, Int((6.0 / Double(parcalar.count)).rounded(.up))))
    print("roster: \(rosterAcik ? "AÇIK" : "KAPALI")")
    print("transkript: \(satirlar.joined(separator: "\n").count) karakter · "
          + "\(satirlar.count) replik")
    print("parça: \(parcalar.count) · hedef parça başına \(hedef) konu\n")

    let clock = ContinuousClock()

    if ProcessInfo.processInfo.environment["GUARDRAIL"] == "1" {
        print("— guardrail: aynı parça istemi 8 kez —")
        var gecen = 0, gr = 0, diger = 0
        for _ in 1 ... 8 {
            let s = LanguageModelSession(instructions: ins)
            do {
                _ = try await s.respond(to: parcaIstemi(parcalar[0], hedef: hedef),
                                        generating: ParcaOzeti.self)
                gecen += 1
            } catch let e as LanguageModelSession.GenerationError {
                if case .guardrailViolation = e { gr += 1 } else { diger += 1 }
            } catch { diger += 1 }
        }
        print("başarılı \(gecen)/8 · guardrail \(gr) · diğer hata \(diger)\n")
    }

    let t0 = clock.now
    var basliklar: [String] = []; var maddeSayilari: [Int] = []
    var maddeUzunluk: [Int] = []; var notlar: [String] = []
    var aksiyonlar: [Ozet.Aksiyon] = []; var atlanan = 0

    for p in parcalar {
        let s = LanguageModelSession(instructions: ins)
        do {
            let r = try await s.respond(to: parcaIstemi(p, hedef: hedef),
                                        generating: ParcaOzeti.self)
            for k in r.content.konular.prefix(hedef) {
                basliklar.append(k.baslik)
                maddeSayilari.append(k.maddeler.count)
                maddeUzunluk.append(contentsOf: k.maddeler.map(\.count))
                notlar.append(([k.baslik] + k.maddeler.map { "- \($0)" }).joined(separator: "\n"))
            }
            aksiyonlar.append(contentsOf: r.content.aksiyonlar)
        } catch { atlanan += 1; print("parça hatası: \(error)") }
    }

    print("map süresi: \(clock.now - t0)  (taban 47,9 sn)")

    let s = LanguageModelSession(instructions: ins)
    var ozet: ToplantiOzeti?
    do {
        ozet = try await s.respond(to: """
            Aşağıda bir toplantının konu konu notları var. Bunlardan
            toplantının 4-6 maddelik genel bakışını ve alınan kararları çıkar.
            Kurallar:
            - Genel bakışta her madde tek cümle olsun; önce ne olduğu,
              sonra sonucu.
            - Genel bakışa toplantının tarihini veya süresini yazma.
            - Konu başlıklarını olduğu gibi tekrar etme; ne olduğunu yaz.
            - Karar olarak yalnızca gerçekten karara bağlanmış şeyleri yaz.
            \(tarih)

            \(notlar.joined(separator: "\n\n"))
            """, generating: ToplantiOzeti.self).content
    } catch { print("REDUCE HATASI: \(error)") }
    print("atlanan parça: \(atlanan)")

    print("toplam: \(clock.now - t0)  (taban 55,3 sn)\n")
    print("— yapı (hedef: bölüm 5-7 · madde/bölüm 2-9 · genel bakış 4-6 · aksiyon 2-5) —")
    print("bölüm         : \(basliklar.count)")
    print("madde/bölüm   : \(maddeSayilari.map(String.init).joined(separator: ", "))")
    print("madde uzunluğu: medyan \(medyan(maddeUzunluk)) krk (referans ~134)\n")

    for n in notlar { print(n); print("") }

    // Başlık: ilk parça vs. konu başlıkları
    func baslikUret(_ kaynak: String) async -> String {
        let s = LanguageModelSession(instructions: ins)
        let r = try? await s.respond(to: """
            Bu toplantıya 3-6 kelimelik Türkçe bir başlık ver. Başlık
            toplantının **tamamını** temsil etmeli, tek bir bölümünü değil.
            Tarih yazma, tırnak kullanma, "toplantı" kelimesini gereksizce
            tekrarlama.

            \(kaynak)
            """, generating: Baslik.self)
        return r?.content.b ?? "(üretilemedi)"
    }
    let ilkParcaBaslik = await baslikUret(parcalar[0])
    let hamKonuBaslik = await baslikUret("Toplantının konu başlıkları:\n"
        + basliklar.map { "- \($0)" }.joined(separator: "\n"))
    let gecerli = hamKonuBaslik.split(separator: " ").count <= 7
        && hamKonuBaslik.filter { $0 == "," }.count <= 1
    let konuBaslik = gecerli ? hamKonuBaslik : "\(hamKonuBaslik)  → GEÇERSİZ, ilk parçaya düşer"
    print("\n— başlık —")
    print("  ilk parçadan : \(ilkParcaBaslik)")
    print("  konulardan   : \(konuBaslik)")

    if let ozet {
        print("\n— genel bakış (\(ozet.genelBakis.count)) —")
        ozet.genelBakis.forEach { print("  • \($0)") }
        print("\n— kararlar (\(ozet.kararlar.count)) —")
        ozet.kararlar.forEach { print("  • \($0)") }
    }

    var gorulen = Set<String>()
    let tekil = aksiyonlar
        .filter { !$0.gorev.trimmingCharacters(in: .whitespaces).isEmpty }
        .filter { !durumCumlesiMi($0.gorev) }
        .filter { gorulen.insert($0.gorev.lowercased(with: Locale(identifier: "tr_TR"))).inserted }
        .prefix(8)
    print("\n— aksiyonlar, doğrulama sonrası (\(aksiyonlar.count) ham · \(tekil.count) tekil) —")
    var listeDisi = 0, kotuBaglam = 0, tarihSizinti = 0
    let basliklarLower = Set(basliklar.map { $0.lowercased(with: Locale(identifier: "tr_TR")) })
    _ = basliklarLower
    for ham in tekil {
        let a = dogrula(ham, basliklar: basliklar)
        print("  ☐ \(a.kisi) — \(a.gorev)")
        print("      \(a.baglam.isEmpty ? "(bağlam yok)" : a.baglam)   [\(a.sonTarih)]")
        if a.kisi.lowercased(with: Locale(identifier: "tr_TR")) != "belirtilmedi",
           !roster.contains(a.kisi) { listeDisi += 1 }
        if !a.baglam.isEmpty, a.baglam.split(separator: " ").count < 4 { kotuBaglam += 1 }
        if a.sonTarih.contains("2026") { tarihSizinti += 1 }
    }
    print("\nliste dışı sorumlu adı : \(listeDisi)  (0 olmalı)")
    print("başlığı tekrarlayan bağlam: \(kotuBaglam)  (0 olmalı)")
    print("toplantı tarihi sızıntısı : \(tarihSizinti)  (0 olmalı)")
} }
