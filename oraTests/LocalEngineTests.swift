import Foundation
import Testing
@testable import ora

/// İsteğe bağlı yerel özetleme motoru. Ölçüm RESEARCH.md §37; buradaki
/// testler ölçümün kodda karşılığı olan **kapıları** sabitler: model yoksa
/// ne olur, çıktı beklenen biçimde gelmezse ne olur, bellek yetmezse ne olur.
@Suite("Yerel motor")
struct LocalEngineTests {

    // MARK: - Model deposu

    /// Yol biçimini indirici dayatıyor (`models--org--repo`); hesap tek yerde
    /// durmalı, yoksa "kurulu mu" sorusu yanlış dizine bakar.
    @Test
    func depoYoluHuggingFaceDuzeninde() {
        let url = LocalModelStore.directory(for: .qwen35_9B)
        #expect(url.lastPathComponent == "models--mlx-community--Qwen3.5-9B-MLX-4bit")
        #expect(url.deletingLastPathComponent().lastPathComponent == "models")
    }

    /// Kurulu olmayan model **kurulu sayılmaz** — yarım bir modelle özetlemeye
    /// kalkmak, kullanıcıya 6 GB indirtip hata göstermektir.
    @Test
    func kurulmayanModelKuruluSayilmaz() {
        let hayali = LocalModel(id: "mlx-community/yok-boyle-bir-model",
                                displayName: "Yok", downloadBytes: 1, peakMemoryBytes: 1,
                                contextTokens: 1, measuredCoverage: 0)
        #expect(!LocalModelStore.isInstalled(hayali))
        #expect(LocalModelStore.bytes(hayali) == 0)
    }

    /// Belleği yetmeyen makinede model seçilemez.
    @Test
    func bellekYetmezseModelSecilemez() {
        let devasa = LocalModel(id: "x/y", displayName: "Devasa",
                                downloadBytes: 1, peakMemoryBytes: 10_000_000_000_000,
                                contextTokens: 1, measuredCoverage: 0)
        #expect(!LocalModelStore.fits(devasa))
        let ufak = LocalModel(id: "x/z", displayName: "Ufak",
                              downloadBytes: 1, peakMemoryBytes: 1,
                              contextTokens: 1, measuredCoverage: 0)
        #expect(LocalModelStore.fits(ufak))
    }

    // MARK: - Çıktıyı çözme

    /// Şema zorlaması olmayan bir modelde JSON'u düz metinden ayıklamak
    /// **şart**: model yanıtı açıklamayla sarabiliyor.
    @Test
    func jsonDuzMetinIcindenAyiklanir() {
        let payload = LocalIntelligence.json(in: """
            İşte toplantı notları:
            {"overview": ["Bütçe 400 bin TL'ye çıkarıldı."], "decisions": [],
             "actions": [], "topics": [{"title": "Bütçe", "bullets": ["Onay nisanda."]}]}
            Umarım işine yarar.
            """)
        #expect(payload?.overview == ["Bütçe 400 bin TL'ye çıkarıldı."])
        #expect(payload?.topics.first?.title == "Bütçe")
    }

    /// Metin içindeki süslü parantez ayıklamayı bozmamalı.
    @Test
    func metindekiParantezAyiklamayiBozmaz() {
        let payload = LocalIntelligence.json(in: """
            {"overview": ["Şablon {ad} olarak yazılıyor."], "decisions": [],
             "actions": [], "topics": []}
            """)
        #expect(payload?.overview == ["Şablon {ad} olarak yazılıyor."])
    }

    @Test
    func jsonYoksaNilDoner() {
        #expect(LocalIntelligence.json(in: "Bugün toplantı çok verimliydi.") == nil)
        #expect(LocalIntelligence.json(in: "{bozuk json") == nil)
    }

    // MARK: - Kapılar

    /// Model indirilmemişse motor **kullanılamaz** der; bu, arayüzün
    /// "Ayarlar'dan indirin" mesajını gösterdiği yer.
    @Test
    func modelYokkaMotorKullanilamaz() {
        let engine = LocalIntelligence(
            model: LocalModel(id: "x/yok", displayName: "Yok", downloadBytes: 1,
                              peakMemoryBytes: 1, contextTokens: 1, measuredCoverage: 0),
            fallback: FailingIntelligence())
        #expect(engine.availability == .localModelMissing)
        #expect(!engine.availability.isAvailable)
        #expect(engine.availability.turkishMessage.contains("indirilmemiş"))
    }

    /// **Sessizce düşme.** Kullanıcı yerel motoru seçmiş ama model kurulu
    /// değilse özet üretilmeden kalmaz — Apple modeline düşülür.
    @Test
    func modelYokkaAppleModelineDusulur() async throws {
        let h = try Harness(intelligence: SlowIntelligence(tag: "apple", step: .milliseconds(1)))
        h.settings.summaryEngine = .local
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.summary?.genelBakis.first?.contains("apple") == true,
                "yerel model yokken Apple motoru koştu")
    }

    /// Yerel motor kuruluysa özeti **o** üretir; noktalama ve başlık Apple'da
    /// kalır (devralınan tek iş özetleme).
    @Test
    func yerelMotorKuruluysaOzetiOUretir() async throws {
        let yerel = SlowIntelligence(tag: "yerel", step: .milliseconds(1))
        let h = try Harness(intelligence: SlowIntelligence(tag: "apple", step: .milliseconds(1)),
                            localIntelligence: yerel)
        h.settings.summaryEngine = .local
        let id = try await h.seed(text: "toplantı metni")
        await h.controller.refresh()
        h.controller.selection = id
        await waitUntil("transkript yüklendi") { !h.controller.transcript.isEmpty }

        await h.controller.summarizeNow()

        #expect(h.controller.summary?.genelBakis.first?.contains("yerel") == true)
    }
}
