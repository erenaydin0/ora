import Foundation
import FoundationModels

let replikler = [
    "toplantıya başlamadan önce geçen haftaki aksiyonları gözden geçirelim",
    "entegrasyon testlerinin yüzde sekseni bitti kalanı cuma gününe kadar tamamlarım",
    "şirket içi güvenlik denetimi çarşamba gününe ertelendi bütçe onayını perşembeye kadar ileteceğim",
    "yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri bildirimleri değerlendirilecek",
    "anlaşıldı ben de test raporunu pazartesi paylaşırım",
]
let ins = "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver."

func istem(_ satirlar: [String]) -> String {
    let n = satirlar.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    return """
    Aşağıdaki numaralı satırlara noktalama işaretleri ve büyük harf düzeltmesi ekle.
    Kuralar:
    - Kelimeleri DEĞİŞTİRME, EKLEME veya SİLME. Yalnızca noktalama ve büyük/küçük harf.
    - Satır sayısını ve numaralandırmayı aynen koru.
    - Yorum, açıklama veya başlık ekleme.

    \(n)
    """
}

func kosu(_ ad: String, _ satirlar: [String], _ tekrar: Int) async {
    var ok = 0, guardrail = 0, diger = 0
    for _ in 1...tekrar {
        let s = LanguageModelSession(instructions: ins)
        do { _ = try await s.respond(to: istem(satirlar)); ok += 1 }
        catch let e as LanguageModelSession.GenerationError {
            if case .guardrailViolation = e { guardrail += 1 } else { diger += 1 }
        } catch { diger += 1 }
    }
    print("\(ad): başarı \(ok)/\(tekrar) · guardrail \(guardrail) · diğer \(diger)")
}

@main struct R { static func main() async {
    await kosu("öneksiz (uygulamadaki biçim)", replikler, 8)
    await kosu("konuşmacı önekli    ", replikler.enumerated().map {
        ($0.offset % 2 == 0 ? "Ben: " : "Katılımcı: ") + $0.element }, 8)
} }
