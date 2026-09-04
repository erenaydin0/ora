import Foundation
import FoundationModels

let replikler = [
    "toplantıya başlamadan önce geçen haftaki aksiyonları gözden geçirelim",
    "entegrasyon testlerinin yüzde sekseni bitti kalanı cuma gününe kadar tamamlarım",
    "şirket içi güvenlik denetimi çarşamba gününe ertelendi bütçe onayını perşembeye kadar ileteceğim",
    "yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri bildirimleri değerlendirilecek",
    "anlaşıldı ben de test raporunu pazartesi paylaşırım",
]

@Generable
struct Noktalanmis {
    @Guide(description: "Noktalama eklenmiş satırlar, girdiyle aynı sırada ve aynı sayıda")
    var satirlar: [String]
}

func dene(_ ad: String, instructions: String?, prompt: String) async -> String {
    let s = instructions.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
    do { let r = try await s.respond(to: prompt); return "✅ \(ad)\n\(r.content)\n" }
    catch { return "❌ \(ad) → \(error)\n" }
}

@main struct G { static func main() async {
    let numarali = replikler.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let duz = replikler.joined(separator: "\n")

    print(await dene("A: özgün istem (numaralı + 'DEĞİŞTİRME')",
        instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.",
        prompt: """
        Aşağıdaki numaralı satırlara noktalama işaretleri ve büyük harf düzeltmesi ekle.
        Kuralar:
        - Kelimeleri DEĞİŞTİRME, EKLEME veya SİLME. Yalnızca noktalama ve büyük/küçük harf.
        - Satır sayısını ve numaralandırmayı aynen koru.
        - Yorum, açıklama veya başlık ekleme.

        \(numarali)
        """))

    print(await dene("B: yumuşak dil, büyük harf yok",
        instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.",
        prompt: """
        Aşağıdaki metne noktalama işaretleri ekle. Her satırı ayrı ayrı işle ve \
        satır sayısını koru.

        \(numarali)
        """))

    print(await dene("C: talimatsız oturum",
        instructions: nil,
        prompt: "Aşağıdaki satırlara noktalama ekle, satır sayısını koru:\n\n\(numarali)"))

    print(await dene("D: numarasız düz metin",
        instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.",
        prompt: "Aşağıdaki satırlara noktalama işaretleri ekle:\n\n\(duz)"))

    print(await dene("E: tek satır",
        instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.",
        prompt: "Bu cümleye noktalama ekle: \(replikler[2])"))

    // F: @Generable şema ile
    let s = LanguageModelSession(instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.")
    do {
        let r = try await s.respond(to: """
            Aşağıdaki satırlara noktalama işaretleri ekle. Satır sayısını koru.

            \(numarali)
            """, generating: Noktalanmis.self)
        print("✅ F: @Generable şema — \(r.content.satirlar.count) satır")
        r.content.satirlar.forEach { print("   \($0)") }
    } catch { print("❌ F: @Generable şema → \(error)") }
} }
