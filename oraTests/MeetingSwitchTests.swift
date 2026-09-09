import Foundation
import Testing
@testable import ora

/// RESEARCH.md §27'nin denetimi. `probes/meeting_switch.swift`'ten taşındı:
/// bir toplantı özetlenirken kenar çubuğundan başka bir toplantıya geçmek
/// arayüzü bozuyor mu?
///
/// Bu takım refactor'ın **doğruluk ölçütüdür**: hattın ürettiği içeriğin
/// yalnızca kendi toplantısının ekranına yazıldığını ölçer.
@Suite("Toplantı geçişi (RESEARCH §27)", .serialized)
struct MeetingSwitchTests {

    @Test
    func islemSurerkenToplantiDegistirmek() async throws {
        let model = SlowIntelligence(tag: "A")
        let h = try Harness(intelligence: model)
        let a = try await h.seed(text: "A toplantısının metni")
        let b = try await h.seed(text: "B toplantısının metni")
        // B'nin hazır bir özeti var — A işlenirken üstüne yazılmamalı.
        try await h.store.saveSummary(b, ozet: Ozet(genelBakis: ["B'nin kendi özeti"],
                                                    kararlar: [], aksiyonlar: []),
                                      topics: [])
        await h.controller.refresh()
        h.controller.selection = a
        await waitUntil("A'nın transkripti yüklendi") {
            h.controller.transcript.first?.text == "A toplantısının metni"
        }

        // 1) A seçili, özetleme başlatılıyor
        let job = Task { await h.controller.summarizeNow() }
        await waitUntil("A'nın ekranında animasyon var") { h.controller.isProcessingSelected }

        // 2) İşlem sürerken B'ye geçiliyor
        h.controller.selection = b
        await waitUntil("B'nin transkripti yüklendi") {
            h.controller.transcript.first?.text == "B toplantısının metni"
        }
        #expect(!h.controller.isProcessingSelected, "B'nin ekranında animasyon YOK")
        #expect(h.controller.transcriptionStage == .idle, "B'nin aşaması .idle")
        #expect(h.controller.summary?.genelBakis.first == "B'nin kendi özeti",
                "B kendi özetini gösteriyor")
        #expect(h.controller.isTranscribing, "hat hâlâ koşuyor (menü barı doğru)")

        // 3) İşlem sürerken A'ya geri dönülüyor. İki ilerleme bildirimi
        //    **arasında** dönülüyor: kullanıcının gördüğü "gidip gelince
        //    düzeliyor" tam olarak burada ölçülür.
        h.controller.selection = a
        await settle(.milliseconds(200))
        #expect(h.controller.isProcessingSelected, "A'ya dönünce animasyon HEMEN var")

        // 4) İşlem sürerken tekrar B'ye, sonra bitiş bekleniyor
        h.controller.selection = b
        _ = await job.value
        await settle()
        #expect(!h.controller.isProcessingSelected, "bitişte B'de animasyon yok")
        #expect(h.controller.summary?.genelBakis.first == "B'nin kendi özeti",
                "B'nin ekranı A'nın özetiyle ezilmedi")

        let bRow = try await h.store.load(b)
        #expect(bRow?.summary?.genelBakis.first == "B'nin kendi özeti",
                "B'nin veritabanı satırı bozulmadı")
        let aRow = try await h.store.load(a)
        #expect(aRow?.summary?.genelBakis.first == "A genel bakış: A toplantısının metni.",
                "A'nın özeti A'nın metninden üretilip A'ya yazıldı")

        // 5) A'ya dönülüyor
        h.controller.selection = a
        await waitUntil("A dönüşte kendi özetini gösteriyor") {
            h.controller.summary?.genelBakis.first == "A genel bakış: A toplantısının metni."
        }
        #expect(!h.controller.isProcessingSelected, "A'da animasyon bitti")
    }

    /// Hat yalnızca **kendi** toplantısının metniyle çağrılmalı. Ekrandaki
    /// toplantının metnini okursa özet yanlış toplantıdan üretilir.
    @Test
    func hatKendiMetniyleCalisir() async throws {
        let model = SlowIntelligence(tag: "A", step: .milliseconds(120))
        let h = try Harness(intelligence: model)
        let a = try await h.seed(text: "A toplantısının metni")
        let b = try await h.seed(text: "B toplantısının metni")
        await h.controller.refresh()
        h.controller.selection = a
        await waitUntil("A yüklendi") { h.controller.transcript.first?.text == "A toplantısının metni" }

        let job = Task { await h.controller.summarizeNow() }
        h.controller.selection = b
        _ = await job.value

        #expect(model.summarizedTexts == ["A toplantısının metni."],
                "özetleme yalnızca A'nın metniyle çağrıldı")
    }
}
