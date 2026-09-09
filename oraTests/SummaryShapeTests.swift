import Foundation
import Testing
@testable import ora

/// Özetin **biçimini** koruyan kurallar: anlatım yerine bilgi, kanıtlı
/// aksiyon, başlığın karar sanılmaması. Hepsi RESEARCH.md §33'te ölçüldü;
/// buradaki testler ölçümün kodda karşılığı olan saf işlevleri sabitler.
@Suite("Özetin biçimi")
struct SummaryShapeTests {

    // MARK: - Aksiyon süzgeci

    /// **Gövdeleme hatası:** `words(of:)` her kelimeyi 5 harfe kırpıyor ve
    /// filtrenin aradığı ek tam da orada kayboluyordu ("açıklıyor" → "acikl").
    /// Süzgeç bu yüzden pratikte hiç çalışmadı.
    @Test
    func anlatimCumlesiAksiyonSayilmaz() {
        #expect(FoundationIntelligence.isStatusNotTask("Levenshtein algoritmasını açıklıyor"))
        #expect(FoundationIntelligence.isStatusNotTask("Token'ı şirket ayarlarına ekledi"))
        #expect(FoundationIntelligence.isStatusNotTask("Ürün hakkında bilgi istedi"))
        #expect(FoundationIntelligence.isStatusNotTask("Kayıt paylaşımını kontrol ediyor"))
    }

    @Test
    func gercekIsAksiyonKalir() {
        #expect(!FoundationIntelligence.isStatusNotTask("Webinar lead listesini paylaş"))
        #expect(!FoundationIntelligence.isStatusNotTask("Pernet ile tanıtım toplantısı ayarla"))
        #expect(!FoundationIntelligence.isStatusNotTask("Partner listesini İlknur'a gönder"))
    }

    /// Uzun ve zayıf bir liste gerçek aksiyonları gömüyor; kanıtı olan öne
    /// alınır, kuyruk kesilir. Eşit kanıtta konuşma sırası korunur.
    @Test
    func aksiyonlarKanitinaGoreSiralanir() {
        func action(_ kisi: String, _ gorev: String, baglam: String = "",
                    tarih: String = "belirtilmedi") -> Ozet.Aksiyon {
            Ozet.Aksiyon(kisi: kisi, gorev: gorev, baglam: baglam, sonTarih: tarih)
        }
        let input = (1...9).map { action("belirtilmedi", "iş \($0)") }
            + [action("Osman Baykal", "listeyi gönder", baglam: "Partner listesi konuşuldu")]
        let ranked = FoundationIntelligence.ranked(input)

        #expect(ranked.count == 8, "kuyruk kesildi")
        #expect(ranked.first?.kisi == "Osman Baykal", "kanıtı olan başa geldi")
        #expect(ranked.dropFirst().map(\.gorev) == (1...7).map { "iş \($0)" },
                "eşit kanıtta konuşma sırası korunuyor")
    }

    @Test
    func kisaListeyeDokunulmaz() {
        let input = (1...5).map {
            Ozet.Aksiyon(kisi: "belirtilmedi", gorev: "iş \($0)", baglam: "",
                         sonTarih: "belirtilmedi")
        }
        #expect(FoundationIntelligence.ranked(input) == input)
    }

    // MARK: - Madde temizliği

    /// "Mert Pamuk, ürün hakkında genel bilgi verdi." — konuşma fiili, sayı
    /// yok, ad ve dolgu kelimeler düşünce geriye bir şey kalmıyor.
    @Test
    func icerikTasimayanAnlatimMaddesiAtilir() {
        let speakers: Set<String> = ["Mert Pamuk", "Çağrı Kilit"]
        #expect(FoundationIntelligence.isEmptyNarration(
            "Mert Pamuk, ürün hakkında genel bilgi verdi.", speakers: speakers))
        #expect(FoundationIntelligence.isEmptyNarration(
            "Çağrı Kilit, konu hakkında bilgi verdi.", speakers: speakers))
    }

    /// Olgu taşıyan madde, konuşma fiiliyle bitse de kalır — Circleback
    /// referansı da bu kalıbı kullanıyor.
    @Test
    func olguTasiyanAnlatimMaddesiKalir() {
        let speakers: Set<String> = ["Mert Pamuk"]
        #expect(!FoundationIntelligence.isEmptyNarration(
            "Mert Pamuk, Kola İK'dan gelen TC kimlikle Edenred verilerinin "
                + "merge edildiğini belirtti.", speakers: speakers))
        #expect(!FoundationIntelligence.isEmptyNarration(
            "Levenshtein eşiği %85 olarak belirlendi.", speakers: speakers))
    }

    /// Model maddeyi alıntı olarak kuruyor: "Çağrı Kilit: 'Bunu no-code yaptık.'"
    @Test
    func konusmaciOnekiVeTirnakKesilir() {
        let cleaned = FoundationIntelligence.cleaned(
            ["Çağrı Kilit: \"Bunu da no-code yaptık.\"",
             "- Mert Pamuk: Doka tarafında akışlar geliyor."],
            speakers: ["Çağrı Kilit", "Mert Pamuk"])

        #expect(cleaned == ["Bunu da no-code yaptık.", "Doka tarafında akışlar geliyor."])
    }

    /// Tanınmayan bir önek kesilmez — "Karar: …" meşru bir madde başlangıcıdır.
    @Test
    func mesruOnekKorunur() {
        let cleaned = FoundationIntelligence.cleaned(["Karar: bütçe onaylandı."],
                                                     speakers: ["Mert Pamuk"])
        #expect(cleaned == ["Karar: bütçe onaylandı."])
    }

    // MARK: - Birleştirme girdisi

    /// Birleştirmeye **başlık gönderilmez**: 11 konulu gerçek bir toplantıda
    /// kararların altısı da konu başlığından kopyalanmıştı.
    @Test
    func birlestirmeGirdisindeBaslikYok() {
        let topics = [
            TopicSegment(title: "Levenshtein Algoritması",
                         bullets: ["Eşik %85 olarak ayarlandı."], start: 0, end: 10),
            TopicSegment(title: "Validasyon Yönetimi",
                         bullets: ["Kurallar JSON dosyalarında tutuluyor."], start: 10, end: 20),
        ]
        let rendered = FoundationIntelligence.render(topics, bulletCap: 6)

        #expect(!rendered.contains("Levenshtein Algoritması"))
        #expect(!rendered.contains("Validasyon Yönetimi"))
        #expect(rendered.contains("Eşik %85 olarak ayarlandı."))
        #expect(rendered.contains("Kurallar JSON dosyalarında tutuluyor."))
    }

    /// İstemdeki örnek cümle çıktıya sızarsa kesilir — örnek modeli belirgin
    /// biçimde düzeltiyor, sızıntı ise sınırlı ve tanınabilir.
    @Test
    func istemOrnegiSizarsaKesilir() {
        let cleaned = FoundationIntelligence.cleaned(
            ["Ödeme akışı üç adımdan oluşuyor.", "Gerçek bir madde."], speakers: [])
        #expect(cleaned == ["Gerçek bir madde."])
    }

    // MARK: - Konuşmacı satırı

    /// İçe aktarılan dökümde satırlar gerçek adlarla başlıyor; orada
    /// "Ben kaydı tutan kişidir" cümlesi aksiyonları sahipsiz bırakıyordu.
    @Test
    func adliDokumdeBenCumlesiYazilmaz() {
        let named = SummaryContext(meetingDate: .now, participants: [], userName: "Eren",
                                   hasNamedSpeakers: true)
        #expect(!FoundationIntelligence.speakerLine(named).contains("Ben"))

        let channels = SummaryContext(meetingDate: .now, participants: [], userName: "Eren")
        #expect(FoundationIntelligence.speakerLine(channels).contains("Ben"))
    }
}
