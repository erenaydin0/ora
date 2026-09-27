import AVFoundation
@preconcurrency import CoreML
import OraDiarizationKit
import Foundation

/// Cihaz üstü konuşmacı ayrımı: pyannote **community-1** (powerset
/// segmentasyon + WeSpeaker ResNet34 gömme + PLDA/VBx kümeleme), FluidAudio'nun
/// CoreML dönüşümüyle. Karar ve gerekçe COMPETITION.md §4.13 / RESEARCH.md §39:
/// Anarlog'un (eski Hyprnote) kullandığı pyannote 3.1 ailesinin Swift yerel
/// karşılığı; Apache 2.0, SPM bağımlılığı yok, bakımlı.
///
/// **Modeller uygulamanın içindedir** (`Diarization.bundle`, 21,6 MB) ve
/// buradan **elle** yüklenir. FluidAudio'nun `ModelHub`'ı HuggingFace'ten
/// indirebilir; o yol hiç çağrılmaz ve `ModelHub.offlineMode` ayrıca açılır.
/// Bağlantı Kuralları: kullanıcının bağlamadığı hiçbir hizmete istek atılmaz,
/// varsayılan yol sıfır indirme.
///
/// **Oturum saklanmaz** — `LocalIntelligence` gibi her çağrıda yüklenir ve
/// iş bitince bırakılır. Derlenmiş `.mlmodelc` yüklemesi ucuzdur.
nonisolated final class FluidDiarizer: Diarizing {

    /// Paket içindeki model klasörü. Testte başka bir yer verilebilir.
    let modelsURL: URL?

    init(modelsURL: URL? = Bundle.main.url(forResource: "Diarization",
                                           withExtension: "bundle")) {
        self.modelsURL = modelsURL
    }

    static let requiredFiles = [
        "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc",
        "PldaRho.mlmodelc", "plda-parameters.json",
    ]

    var isAvailable: Bool {
        guard let modelsURL else { return false }
        return Self.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: modelsURL.appendingPathComponent($0).path)
        }
    }

    @concurrent func turns(url: URL, channel: Channel,
                           progress: @Sendable @escaping (Double) -> Void) async throws
        -> [SpeakerTurn] {
        guard let modelsURL, isAvailable else {
            throw OraError.diarizationFailed(reason: "Konuşmacı ayrımı modelleri bulunamadı")
        }
        // Kütüphanenin indirme yolu kapalı: modeller eksikse ağa gitmek yerine
        // hata verir.
        ModelHub.offlineMode = true

        let started = Date()
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: try Self.loadModels(from: modelsURL))

        let source = try ChannelSampleSource(url: url, channel: channel)
        defer { source.cleanup() }
        Log.info(.transcribe, "Konuşmacı ayrımı: \(channel.databaseValue) kanalı, "
                 + String(format: "%.0f sn", Double(source.sampleCount) / ChannelSampleSource.sampleRate))

        let result = try await manager.process(audioSource: source,
                                               audioLoadingSeconds: 0) { done, total in
            progress(Double(done) / Double(max(total, 1)))
        }
        let turns = result.segments.map {
            SpeakerTurn(start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds),
                        speaker: $0.speakerId)
        }
        Log.info(.transcribe, "Konuşmacı ayrımı bitti — \(Set(turns.map(\.speaker)).count) küme, "
                 + "\(turns.count) tur, "
                 + String(format: "%.1f sn", Date().timeIntervalSince(started)))
        return turns
    }

    /// Dört modeli ve PLDA parametresini paketten yükler — `ModelHub`'a
    /// dokunmadan. Hesap birimleri FluidAudio'nun kendi seçimiyle aynı:
    /// segmentasyon/gömme/PLDA `.all`, FBank `.cpuOnly` (orada daha hızlı).
    static func loadModels(from directory: URL) throws -> OfflineDiarizerModels {
        let started = Date()
        let inference = MLModelConfiguration()
        inference.computeUnits = .all
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly

        func model(_ name: String, _ configuration: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: directory.appendingPathComponent(name),
                        configuration: configuration)
        }
        return OfflineDiarizerModels(
            segmentationModel: try model("Segmentation.mlmodelc", inference),
            fbankModel: try model("FBank.mlmodelc", cpu),
            embeddingModel: try model("Embedding.mlmodelc", inference),
            pldaRhoModel: try model("PldaRho.mlmodelc", inference),
            pldaPsi: try pldaPsi(from: directory.appendingPathComponent("plda-parameters.json")),
            compilationDuration: Date().timeIntervalSince(started))
    }

    /// `plda-parameters.json` içindeki `psi` tensörü: base64 Float32 dizisi.
    /// FluidAudio'nun okuyucusu `private`; biçim aynı şekilde çözülür.
    static func pldaPsi(from url: URL) throws -> [Double] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let tensors = root?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              data.count >= MemoryLayout<Float>.size
        else {
            throw OraError.diarizationFailed(reason: "PLDA parametreleri okunamadı")
        }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

/// Kaydın **tek kanalını** 16 kHz mono Float32 olarak diskten okuyan kaynak.
///
/// Kanal ayrıdır çünkü kanallar asla karıştırılmaz (kural #11): FluidAudio'nun
/// kendi dosya kaynağı stereo dosyayı monoya indirir ve mikrofonla karşı
/// tarafı tek akışa katardı. Ses **RAM'de tutulmaz** (kural #12'nin ruhu):
/// kanal geçici bir dosyaya parça parça yazılır ve bellek eşlemeyle okunur —
/// 60 dakikalık kanal 230 MB'lık bir dizi olmaz.
nonisolated struct ChannelSampleSource: AudioSampleSource {

    static let sampleRate: Double = 16_000

    private let data: Data
    private let fileURL: URL
    let sampleCount: Int

    init(url: URL, channel: Channel) throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: SpeechTranscription.monoFormat(source),
                                               to: target)
        else {
            throw OraError.diarizationFailed(reason: "Ses biçimi okunamadı")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-diarize-\(UUID().uuidString).f32")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        // Bir saniyelik parçalar — tam geçişle aynı okuma deseni.
        let chunk = AVAudioFrameCount(source.sampleRate)
        while file.framePosition < file.length {
            let want = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: want) else { break }
            do {
                try file.read(into: input, frameCount: want)
            } catch {
                // Dosya sonundaki `nilError` (RESEARCH.md §22) gerçek bir hata değil.
                guard file.framePosition >= file.length else { throw error }
                break
            }
            guard input.frameLength > 0,
                  let mono = SpeechTranscription.extract(channel: channel, from: input),
                  let converted = SpeechTranscription.convert(mono, using: converter, to: target),
                  let samples = converted.floatChannelData?[0]
            else { continue }
            handle.write(Data(bytes: samples,
                              count: Int(converted.frameLength) * MemoryLayout<Float>.size))
        }
        try handle.synchronize()

        data = try Data(contentsOf: temporary, options: .alwaysMapped)
        fileURL = temporary
        sampleCount = data.count / MemoryLayout<Float>.size
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>,
                     offset: Int, count: Int) throws {
        guard count > 0, offset < sampleCount else { return }
        let start = max(0, offset)
        let available = min(sampleCount - start, count)
        guard available > 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            destination.update(from: base.advanced(by: start), count: available)
        }
    }

    /// Geçici dosya silinir. Eşleme açık kalsa da inode yaşar; silmek güvenli.
    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
