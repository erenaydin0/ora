// Bu makinede FoundationModels hangi modelleri sunuyor?
// "Daha güçlü bir üst model var mı" sorusunun ölçülmüş yanıtı.
import Foundation
import FoundationModels

func durum(_ m: SystemLanguageModel) -> String {
    switch m.availability {
    case .available: "kullanılabilir"
    case .unavailable(.deviceNotEligible): "cihaz uygun değil"
    case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence kapalı"
    case .unavailable(.modelNotReady): "model hazır değil"
    case .unavailable(let r): "kullanılamıyor: \(r)"
    }
}

@main struct M { static func main() async {
    let genel = SystemLanguageModel.default
    print("SystemLanguageModel.default        : \(durum(genel))")
    print("  isAvailable                      : \(genel.isAvailable)")

    let etiket = SystemLanguageModel(useCase: .contentTagging)
    print("SystemLanguageModel(.contentTagging): \(durum(etiket))")

    print("\nDesteklenen diller (\(genel.supportedLanguages.count)):")
    let diller = genel.supportedLanguages
        .map { $0.maximalIdentifier }
        .sorted()
    print("  " + diller.joined(separator: ", "))
    print("\ntr-Latn-TR destekli mi: "
          + "\(diller.contains(where: { $0.hasPrefix("tr") }))")

    // Bağlam penceresi tek gerçek kapasite göstergesi; ölçerek yazalım.
    let s = LanguageModelSession(instructions: "Kısa yanıt ver.")
    do {
        let r = try await s.respond(to: "Merhaba, tek kelimeyle yanıt ver.")
        print("\nörnek yanıt: \(r.content.prefix(60))")
    } catch { print("\nörnek yanıt hatası: \(error)") }
} }
