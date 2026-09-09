import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Dışarıdan gelen bir ses (ya da video) dosyasını hattın okuyabileceği
/// biçime çevirir: **16 kHz · mono · WAV**.
///
/// Neden mono — kendi kaydımız stereo yazılır ve kanal ayrımı "ben vs. karşı
/// taraf"ı çözer (kural #11). İçe aktarılan dosyada böyle bir gerçek **yok**:
/// telefonla kaydedilmiş bir toplantının iki kanalı aynı odayı duyar. İki
/// kanalı da çözmek aynı konuşmayı iki kez transkripte yazardı; kanalların
/// birini "Ben" saymak ise bütün aksiyonları kullanıcının üstüne yıkardı.
/// Bu yüzden tek akışa indirilir ve `Channel.system` ("Katılımcı") olarak
/// çözülür — kendinden emin yanlış bir ad, boş bir alandan kötüdür
/// (COMPETITION.md §4.14).
///
/// Neden çeviriyoruz da kopyalamıyoruz — kaynak mp3, m4a, video konteyneri
/// ya da 48 kHz stereo olabilir. Tek bir biçme indirmek hattın tamamını
/// (tepe ölçümü, kanal ayırma, oynatıcı, AAC sıkıştırma) tek kod yolunda
/// tutuyor. Kullanıcının **kendi dosyasına dokunulmaz**; okunur, kopyası
/// yazılır.
///
/// `AVAssetReader` kullanılır, `AVAudioFile` değil: Zoom kaydı `.mp4`
/// konteynerinden gelir ve `ExtAudioFile` video parçası olan bir dosyayı
/// açmaz.
nonisolated enum AudioImport {

    /// Speech motoru zaten 16 kHz'e indiriyor; kaynağı daha yüksek tutmanın
    /// karşılığı yok, diskte yeri var.
    static let sampleRate = 16_000.0

    /// Dosya seçicide ve sürükle-bırakta kabul edilen türler.
    /// `.movie` de var: toplantı kaydı çoğu zaman `.mp4` gelir.
    static let contentTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]

    /// Bu uzantı ses olarak içe alınır. Sürükle-bırakta `UTType` her zaman
    /// çözülmüyor (harici disk, ağ paylaşımı); uzantı ikinci kapıdır.
    static let fileExtensions: Set<String> = [
        "wav", "wave", "m4a", "mp3", "aac", "aif", "aiff", "aifc", "caf",
        "mp4", "mov", "m4v", "flac", "ogg", "opus", "amr", "3gp",
    ]

    /// - Returns: yazılan sesin saniye cinsinden uzunluğu.
    /// - Throws: `OraError.importFailed` — kaynakta ses yoksa, çözülemiyorsa
    ///   ya da çıktı boş kaldıysa. Yarım kalan çıktı diskte bırakılmaz.
    @concurrent static func convert(_ source: URL, to target: URL,
                                    progress: @Sendable @escaping (Double) -> Void) async throws
        -> TimeInterval {

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw OraError.importFailed(reason: "Dosya açılamadı: \(error.localizedDescription)")
        }
        guard !tracks.isEmpty else {
            throw OraError.importFailed(reason: "Bu dosyada ses parçası yok.")
        }
        let assetDuration = ((try? await asset.load(.duration))?.seconds).flatMap {
            $0.isFinite ? $0 : nil
        } ?? 0

        try? FileManager.default.removeItem(at: target)
        do {
            let written = try transcode(tracks: tracks, of: asset, to: target,
                                        expected: assetDuration, progress: progress)
            guard written > 0 else {
                throw OraError.importFailed(reason: "Dosyadan hiç ses okunamadı.")
            }
            progress(1)
            Log.info(.capture, "Ses içe aktarıldı: \(source.lastPathComponent) → "
                     + "\(target.lastPathComponent), "
                     + String(format: "%.1f sn", written)
                     + ", \(AudioArchive.sizeLabel(AudioArchive.bytes(at: target)))")
            return written
        } catch {
            // Yarım WAV bırakmak "yeniden dene" düğmesine bozuk bir dosya verir.
            try? FileManager.default.removeItem(at: target)
            throw error as? OraError
                ?? OraError.importFailed(reason: error.localizedDescription)
        }
    }

    /// Okuma-yazma döngüsü. Ayrı bir metot: `AVAssetReader` senkron çalışır ve
    /// bu gövde baştan sona `@concurrent` bağlamda, ana iş parçacığının
    /// dışında koşar.
    private static func transcode(tracks: [AVAssetTrack], of asset: AVAsset, to target: URL,
                                  expected: TimeInterval,
                                  progress: @Sendable @escaping (Double) -> Void) throws
        -> TimeInterval {

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                                 audioSettings: readerSettings())
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OraError.importFailed(reason: "Ses çözücü kurulamadı.")
        }
        reader.add(output)

        let file = try AVAudioFile(forWriting: target, settings: writerSettings())
        guard reader.startReading() else {
            throw OraError.importFailed(
                reason: reader.error?.localizedDescription ?? "Ses okunamaya başlanamadı.")
        }

        var frames = 0
        let total = max(expected * sampleRate, 1)
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else { continue }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                                    destination: destination)
            guard status == kCMBlockBufferNoErr else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            frames += count
            progress(min(1, Double(frames) / total))
        }

        if reader.status == .failed {
            throw OraError.importFailed(
                reason: reader.error?.localizedDescription ?? "Ses çözümlenemedi.")
        }
        return Double(frames) / sampleRate
    }

    /// Çözücünün çıkışı: 16 kHz, tek kanal, float32.
    ///
    /// Kanal düzeni **açıkça** verilir; çok kanallı (5.1) bir kaynakta düzen
    /// verilmezse `AVAssetReaderAudioMixOutput` mono karışım üretmeyi reddeder.
    private static func readerSettings() -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(bytes: &layout,
                                     count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Diskteki biçim: kendi kaydımızla aynı — 16 kHz · 16 bit · WAV, tek fark
    /// kanal sayısı.
    private static func writerSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}
