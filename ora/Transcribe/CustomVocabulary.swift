import Foundation
import Speech

/// Özel sözlüğü `DictationTranscriber`'ın anlayacağı derlenmiş dil modeline çevirir.
///
/// **Ölçüldü (RESEARCH.md §17):** `weight: 1.0` ve `count: 30` ile terim tutma
/// 2/5'ten 4/5'e çıkıyor. `count`'u yükseltmek (200) sonucu **kötüleştiriyor** —
/// aşırı ağırlıklandırma çevredeki kelimeleri bozuyor. Bu iki sayı ölçümle
/// seçildi; değiştirmeden önce probe'u yeniden koştur.
enum CustomVocabulary {

    static let phraseCount = 30
    static let weight = 1.0

    /// Derlenmiş model `{base}/vocabulary/` altında durur ve sözlük değişmedikçe
    /// yeniden derlenmez.
    private static var directory: URL {
        AppPaths.base.appending(path: "vocabulary", directoryHint: .isDirectory)
    }

    /// Sözlükten derlenmiş yapılandırma üretir. Sözlük boşsa `nil` döner ve
    /// çağıran özel sözlük ipucu vermez.
    static func configuration(for words: [String],
                              locale: Locale) async -> SFSpeechLanguageModel.Configuration? {
        let terms = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        // Sözlük içeriği değişmedikçe aynı sürüm; `prepare` önbelleği kullanır.
        let version = String(terms.sorted().joined(separator: "|").hashValue, radix: 16)
        let assetURL = directory.appending(path: "data-\(version).bin")
        let modelURL = directory.appending(path: "model-\(version).bin")
        let vocabularyURL = directory.appending(path: "vocab-\(version).bin")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = SFCustomLanguageModelData(locale: locale,
                                                 identifier: Bundle.main.bundleIdentifier
                                                    ?? "com.orameetings.ora",
                                                 version: version)
            for term in terms {
                data.insert(phraseCount: .init(phrase: term, count: phraseCount))
            }
            try await data.export(to: assetURL)

            let configuration = SFSpeechLanguageModel.Configuration(
                languageModel: modelURL, vocabulary: vocabularyURL,
                weight: NSNumber(value: weight))
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL, configuration: configuration)
            Log.info(.transcribe, "Özel sözlük derlendi — \(terms.count) terim")
            return configuration
        } catch {
            // Sözlük bir iyileştirmedir; derlenemezse transkripsiyon yine çalışır.
            Log.warning(.transcribe, "Özel sözlük derlenemedi: \(error.localizedDescription)")
            return nil
        }
    }

    /// Eski sürümlerin derlenmiş dosyalarını siler.
    static func pruneOldVersions(keeping version: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !file.lastPathComponent.contains(version) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
