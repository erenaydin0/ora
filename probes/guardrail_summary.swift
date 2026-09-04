import Foundation
import FoundationModels
let ins = "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver."
let base = [
    "toplantıya başlamadan önce geçen haftaki aksiyonları gözden geçirelim",
    "entegrasyon testlerinin yüzde sekseni bitti kalanı cuma gününe kadar tamamlarım",
    "şirket içi güvenlik denetimi çarşamba gününe ertelendi bütçe onayını perşembeye kadar ileteceğim",
    "yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri bildirimleri değerlendirilecek",
    "anlaşıldı ben de test raporunu pazartesi paylaşırım",
]
func kosu(_ ad: String, _ metin: String, _ tekrar: Int) async {
    var ok = 0, g = 0, d = 0
    for _ in 1...tekrar {
        let s = LanguageModelSession(instructions: ins)
        do { _ = try await s.respond(to: """
            Bu toplantı bölümünü Türkçe olarak özetle. Kararları ve kimin neyi
            üstlendiğini mutlaka koru. En fazla 6 cümle.

            \(metin)
            """); ok += 1 }
        catch let e as LanguageModelSession.GenerationError {
            if case .guardrailViolation = e { g += 1 } else { d += 1 }
        } catch { d += 1 }
    }
    print("\(ad): başarı \(ok)/\(tekrar) · guardrail \(g) · diğer \(d)")
}
@main struct S { static func main() async {
    let onekli = base.enumerated().map { ($0.offset % 2 == 0 ? "Ben: " : "Katılımcı: ") + $0.element }
    await kosu("özet · konuşmacı önekli", onekli.joined(separator: "\n"), 8)
    await kosu("özet · öneksiz         ", base.joined(separator: "\n"), 8)
} }
