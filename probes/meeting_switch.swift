// Toplantı geçişi probe'u: bir toplantı özetlenirken kenar çubuğundan başka
// bir toplantıya geçmek arayüzü bozuyor mu?
//
// Gerçek `RecordingController` ve gerçek `MeetingStore` (bellek içi SQLite) ile
// koşar; yalnızca `Intelligent` sahtedir — yavaş çalışır ve ilerleme bildirir,
// böylece "işlem sürerken" penceresi ölçülebilir olur. Ölçüm: RESEARCH.md §27.
//
// Uygulama hedefinin bir kez derlenmiş olması gerekir (GRDB modülü oradan
// gelir). Derle ve koş:
//
//   DD=$(xcodebuild -project ora.xcodeproj -scheme ora -showBuildSettings \
//         | awk -F' = ' '/ BUILD_DIR = /{print $2}')
//   PKG=$(dirname "$(dirname "$DD")")/SourcePackages/checkouts/GRDB.swift
//   xcrun swiftc -o /tmp/meeting_switch -swift-version 6 \
//     -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//     -I "$DD/Debug" -I "$PKG/Sources/GRDBSQLite" -lsqlite3 "$DD/Debug/GRDB.o" \
//     $(find ora -name '*.swift' ! -name 'oraApp.swift') \
//     "$(dirname "$DD")/Intermediates.noindex/ora.build/Debug/ora.build/DerivedSources/GeneratedAssetSymbols.swift" \
//     probes/meeting_switch.swift && /tmp/meeting_switch
import Foundation

/// İlerleme bildiren, yavaş bir sahte model. Özet metni **kendisine verilen**
/// metinden türetilir: yanlış toplantının metniyle çağrıldığında bu iz onu
/// ele verir.
final class SlowIntelligence: Intelligent, @unchecked Sendable {
    var availability: ModelAvailability { .available }
    let tag: String
    /// İki ilerleme bildirimi arası. Gerçek hatta bir parçanın özetlenmesi
    /// saniyeler sürer; sık bildirim, dönüşte animasyonun kendiliğinden geri
    /// gelmesini sağlayıp hatayı gizler.
    let step: Duration = .milliseconds(900)

    init(tag: String) { self.tag = tag }

    func restorePunctuation(_ segments: [Segment],
                            progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        for i in 1...3 {
            try? await Task.sleep(for: step)
            progress(Double(i) / 3)
        }
        return segments.map {
            Segment(channel: $0.channel, speaker: $0.speaker, text: $0.text + ".",
                    start: $0.start, end: $0.end, confidence: $0.confidence, words: $0.words)
        }
    }

    func summarize(_ segments: [Segment], context: SummaryContext, variation: Bool,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> SummaryResult {
        for i in 1...6 {
            try? await Task.sleep(for: step)
            progress(Double(i) / 6)
        }
        let source = segments.first?.text ?? "boş"
        return SummaryResult(
            ozet: Ozet(genelBakis: ["\(tag) genel bakış: \(source)"],
                       kararlar: ["\(tag) karar"],
                       aksiyonlar: [Ozet.Aksiyon(kisi: "Ben", gorev: "\(tag) görev",
                                                 baglam: "\(tag) bağlam",
                                                 sonTarih: "belirtilmedi")]),
            topics: [TopicSegment(title: "\(tag) konu", bullets: ["madde"], start: 0, end: 10)],
            skippedChunks: 0)
    }

    func answer(question: String, over segments: [Segment]) async throws -> String { "" }
    func generateTitle(from segments: [Segment]) async -> String? { nil }
    func generateTitle(from segments: [Segment], topics: [TopicSegment]) async -> String? { nil }
}

@MainActor
func seed(_ store: MeetingStore, text: String) async throws -> Int64 {
    let id = try await store.createMeeting()
    try await store.replaceTranscript(id, segments: [
        Segment(channel: .mic, speaker: "Ben", text: text,
                start: 0, end: 10, confidence: 0.9, words: [])
    ])
    try await store.markReady(id)
    return id
}

@MainActor var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print((condition ? "  ✓ " : "  ✗ ") + label)
    if !condition { failures += 1 }
}

@main
struct Probe {
    @MainActor static func main() async throws {
        try await run()
        print(failures == 0 ? "\nTÜMÜ GEÇTİ" : "\n\(failures) KONTROL BAŞARISIZ")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor
func run() async throws {
    let db = try OraDatabase(path: ":memory:")
    let store = MeetingStore(database: db)
    let a = try await seed(store, text: "A toplantısının metni")
    let b = try await seed(store, text: "B toplantısının metni")
    // B'nin hazır bir özeti var — A işlenirken üstüne yazılmamalı.
    try await store.saveSummary(b, ozet: Ozet(genelBakis: ["B'nin kendi özeti"],
                                              kararlar: [], aksiyonlar: []),
                                topics: [])

    let controller = RecordingController(intelligence: SlowIntelligence(tag: "A"),
                                         database: db)
    await controller.refresh()
    controller.selection = a
    try? await Task.sleep(for: .milliseconds(200))

    print("1) A seçili, özetleme başlatılıyor")
    let job = Task { await controller.summarizeNow() }
    try? await Task.sleep(for: .milliseconds(400))
    check(controller.isProcessingSelected, "A'nın ekranında animasyon var")

    print("2) İşlem sürerken B'ye geçiliyor")
    controller.selection = b
    try? await Task.sleep(for: .milliseconds(300))
    check(!controller.isProcessingSelected, "B'nin ekranında animasyon YOK")
    check(controller.transcriptionStage == .idle, "B'nin aşaması .idle")
    check(controller.summary?.genelBakis.first == "B'nin kendi özeti",
          "B kendi özetini gösteriyor")
    check(controller.transcript.first?.text == "B toplantısının metni",
          "B kendi transkriptini gösteriyor")
    check(controller.isTranscribing, "hat hâlâ koşuyor (menü barı doğru)")

    print("3) İşlem sürerken A'ya geri dönülüyor")
    // İki ilerleme bildirimi **arasında** dönülüyor: kullanıcının gördüğü
    // "gidip gelince düzeliyor" tam olarak burada ölçülür.
    controller.selection = a
    try? await Task.sleep(for: .milliseconds(200))
    check(controller.isProcessingSelected, "A'ya dönünce animasyon HEMEN var")

    print("4) İşlem sürerken tekrar B'ye, sonra bitiş bekleniyor")
    controller.selection = b
    _ = await job.value
    try? await Task.sleep(for: .milliseconds(200))
    check(!controller.isProcessingSelected, "bitişte B'de animasyon yok")
    check(controller.summary?.genelBakis.first == "B'nin kendi özeti",
          "B'nin ekranı A'nın özetiyle ezilmedi")
    let bRow = try await store.load(b)
    check(bRow?.summary?.genelBakis.first == "B'nin kendi özeti",
          "B'nin veritabanı satırı bozulmadı")
    let aRow = try await store.load(a)
    check(aRow?.summary?.genelBakis.first == "A genel bakış: A toplantısının metni.",
          "A'nın özeti A'nın metninden üretilip A'ya yazıldı "
          + "(gelen: \(aRow?.summary?.genelBakis.first ?? "yok"))")

    print("5) A'ya dönülüyor")
    controller.selection = a
    try? await Task.sleep(for: .milliseconds(300))
    check(controller.summary?.genelBakis.first == "A genel bakış: A toplantısının metni.",
          "A dönüşte kendi özetini gösteriyor")
    check(!controller.isProcessingSelected, "A'da animasyon bitti")
}

