import Foundation
import Speech

/// Transkripsiyon dili yönetimi.
///
/// **`SpeechTranscriber` değil `DictationTranscriber` kullanılır** — `SpeechTranscriber`
/// 30 locale destekler ve Türkçe içermez; `DictationTranscriber` 43 locale destekler,
/// `tr_TR` dahildir (RESEARCH.md §2). Bu ayrım projenin can damarıdır.
nonisolated enum TranscriptionLanguage: String, CaseIterable, Sendable, Identifiable {
    case turkish = "tr-TR"
    case english = "en-US"
    /// Kurulu diller arasından, sesin ilk dakikasına bakarak seçer.
    case automatic = "auto"

    var id: String { rawValue }

    var turkishName: String {
        switch self {
        case .turkish:   "Türkçe"
        case .english:   "İngilizce"
        case .automatic: "Otomatik"
        }
    }

    var locale: Locale? {
        switch self {
        case .automatic: nil
        default:         Locale(identifier: rawValue)
        }
    }

    /// Otomatik seçimin aday havuzu.
    static var detectionCandidates: [Locale] {
        [Locale(identifier: "tr-TR"), Locale(identifier: "en-US")]
    }
}

nonisolated enum TranscriptionLocale {

    /// Dil paketi bu makinede kurulu mu?
    static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await DictationTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// `DictationTranscriber`'ın desteklediği eşdeğer locale (tr → tr_TR gibi).
    static func supported(_ locale: Locale) async -> Locale? {
        await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Kurulu değilse indirir. İlerleme 0…1 aralığında bildirilir.
    ///
    /// `maximumReservedLocales` sınırı vardır (bu makinede 5); dil rezerve edilerek
    /// sistem tarafından tahliye edilmesi engellenir.
    static func ensureInstalled(_ locale: Locale,
                                module: any SpeechModule,
                                progress: @Sendable @escaping (Double) -> Void) async throws {
        if await isInstalled(locale) {
            try? await AssetInventory.reserve(locale: locale)
            return
        }
        // Bu çağrı, varlıklar yerindeyken bile bazen hem istek hem hata vermeden
        // dönüyor ve köprü `_GenericObjCError` fırlatıyor. Bu, dil paketinin
        // eksik olduğu anlamına gelmez — hata burada yutulmaz, loga tam hâliyle
        // yazılır ve geçiş sürer; dil gerçekten eksikse analiz motoru kendi
        // hatasını verir. Aksi hâlde kayıt sonrası geçiş, sesi çözebilecekken
        // "Transkripsiyon tamamlanamadı" diye düşüyordu.
        let pending: AssetInstallationRequest?
        do {
            pending = try await AssetInventory.assetInstallationRequest(supporting: [module])
        } catch {
            Log.warning(.transcribe, "\(locale.identifier) dil paketi isteği alınamadı, "
                        + "kurulu varsayılıyor — \(Log.describe(error))")
            try? await AssetInventory.reserve(locale: locale)
            return
        }
        guard let request = pending else {
            // İstek yoksa varlıklar zaten yerinde demektir.
            try? await AssetInventory.reserve(locale: locale)
            return
        }
        Log.info(.transcribe, "\(locale.identifier) dil paketi indiriliyor")
        let observation = Task { @Sendable in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observation.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw OraError.localeNotInstalled(locale)
        }
        try? await AssetInventory.reserve(locale: locale)
        Log.info(.transcribe, "\(locale.identifier) dil paketi kuruldu")
    }

    /// Otomatik dil seçimi.
    ///
    /// Apple'da konuşulan dili tanıyan bir API **yok**. Bunun yerine sesin ilk
    /// bölümü kurulu adaylarla ayrı ayrı çözülür ve ortalama güven skoru yüksek
    /// olan seçilir. Ölçüm 45x gerçek zamanlı olduğu için maliyeti saniyeler mertebesinde.
    static func detect(url: URL, channel: Channel,
                       seconds: TimeInterval = 40) async -> Locale {
        var candidates: [Locale] = []
        for candidate in TranscriptionLanguage.detectionCandidates
        where await isInstalled(candidate) {
            candidates.append(candidate)
        }
        guard candidates.count > 1 else {
            let chosen = candidates.first ?? Locale(identifier: "tr-TR")
            Log.info(.transcribe, "Otomatik dil: tek aday kurulu — \(chosen.identifier)")
            return chosen
        }

        var best = candidates[0]
        var bestScore = -1.0
        for candidate in candidates {
            do {
                let segments = try await SpeechTranscription()
                    .transcribe(url: url, locale: candidate, vocabulary: [],
                                channels: [channel], limit: seconds) { _ in }
                let score = meanConfidence(segments)
                Log.info(.transcribe, "Otomatik dil adayı \(candidate.identifier): "
                         + String(format: "güven %.3f, %d segment", score, segments.count))
                if score > bestScore { bestScore = score; best = candidate }
            } catch {
                Log.warning(.transcribe, "Otomatik dil adayı \(candidate.identifier) "
                            + "denenemedi: \(error.localizedDescription)")
            }
        }
        Log.info(.transcribe, "Otomatik dil seçildi: \(best.identifier)")
        return best
    }

    private static func meanConfidence(_ segments: [Segment]) -> Double {
        let words = segments.flatMap(\.words).compactMap(\.confidence)
        guard !words.isEmpty else { return 0 }
        return words.reduce(0, +) / Double(words.count)
    }
}
