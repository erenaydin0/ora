import Foundation
import FoundationModels

@Generable
struct Ozet {
  @Guide(description: "Toplantının 2 cümlelik Türkçe özeti")
  var genelBakis: String
  @Guide(description: "Alınan kararlar", .maximumCount(4))
  var kararlar: [String]
  @Generable struct Aksiyon {
    @Guide(description: "Sorumlu kişinin adı") var kisi: String
    @Guide(description: "Yapılacak iş") var gorev: String
    @Guide(description: "Son tarih, yoksa 'belirtilmedi'") var sonTarih: String
  }
  @Guide(description: "Aksiyon maddeleri", .maximumCount(5))
  var aksiyonlar: [Aksiyon]
}

@main
struct M {
  static func main() async {
    let transcript = """
    Ben: Toplantıya başlamadan önce geçen haftaki aksiyonları gözden geçirelim. Ayşe, entegrasyon testlerini tamamladı mı?
    Ayşe: Testlerin yüzde sekseni bitti, kalanı cuma gününe kadar tamamlarım.
    Mehmet: Şirket içi güvenlik denetimi çarşamba gününe ertelendi. Bütçe onayını perşembeye kadar ileteceğim.
    Ben: Yeni sürümün çıkış tarihini iki hafta öteliyoruz çünkü müşteri geri bildirimleri değerlendirilecek.
    Ayşe: Anlaşıldı, ben de test raporunu pazartesi paylaşırım.
    """
    let session = LanguageModelSession(instructions: "Sen bir toplantı asistanısın. Toplantı Türkçe ise yanıtını Türkçe ver.")
    let clock = ContinuousClock(); let start = clock.now
    do {
      let r = try await session.respond(to: "Bu toplantı transkriptini özetle:\n\(transcript)", generating: Ozet.self)
      let o = r.content
      print("SÜRE: \(clock.now - start)")
      print("\nGENEL BAKIŞ: \(o.genelBakis)")
      print("\nKARARLAR:"); o.kararlar.forEach { print("  • \($0)") }
      print("\nAKSİYONLAR:"); o.aksiyonlar.forEach { print("  • \($0.kisi) → \($0.gorev) [\($0.sonTarih)]") }
    } catch { print("HATA: \(error)") }
  }
}
