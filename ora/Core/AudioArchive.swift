import AVFoundation
import Foundation

/// Ses kayıtlarının disk yönetimi.
///
/// Neden var: 16 kHz · 16 bit · stereo WAV **saatte ~230 MB** eder (kural #11).
/// Haftada 10 saat toplantı ayda ~9 GB demek. ora sesi saklıyordu ama
/// yönetmiyordu — bu bir hata modudur (COMPETITION.md §4.5).
///
/// Üç işlem: boyutu bildir, sesi AAC'ye çevir, sesi sil. Hiçbiri kendiliğinden
/// çalışmaz; ikisi ayarla açılır, biri kullanıcı ister.
enum AudioArchive {

    /// Kayıtlar dizininin toplam boyutu.
    static func totalBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.recordings, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + bytes(at: $1) }
    }

    static func bytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// "1,4 GB" — kullanıcıya gösterilecek biçim.
    static func sizeLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// WAV'ı AAC'ye (.m4a) çevirir ve WAV'ı siler. Yeni dosyanın URL'ini döner.
    ///
    /// **Ölçüldü (RESEARCH.md §25.3):** 31,8 sn'lik gerçek kayıtta 1.989 KB →
    /// 173 KB (11,5×), 0,09 sn. Kanal ayrımı korunuyor: kaynakta sessiz olan
    /// sistem kanalının tepesi 0,00003 kalıyor — sessiz kanal eşiğinin (0,005)
    /// çok altında, yani "Yeniden dene" yolundaki kanal atlama mantığı bozulmuyor.
    ///
    /// Kayıp veren bir sıkıştırmadır; bu yüzden **opt-in**'dir ve yalnızca
    /// transkripsiyon bittikten sonra çalışır.
    static func compress(_ url: URL) async throws -> URL {
        guard url.pathExtension.lowercased() == "wav" else { return url }
        let target = url.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: target)

        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw OraError.audioWriteFailed(underlying: ArchiveError.exportUnavailable)
        }
        try await session.export(to: target, as: .m4a)
        guard bytes(at: target) > 0 else {
            throw OraError.audioWriteFailed(underlying: ArchiveError.emptyOutput)
        }
        try? FileManager.default.removeItem(at: url)
        Log.info(.capture, "Ses sıkıştırıldı: \(url.lastPathComponent) → "
                 + "\(target.lastPathComponent) (\(sizeLabel(bytes(at: target))))")
        return target
    }

    /// Ses dosyasını siler. Transkript, özet ve aksiyonlar kalır.
    @discardableResult
    static func delete(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try FileManager.default.removeItem(atPath: path)
            Log.info(.capture, "Ses silindi: \((path as NSString).lastPathComponent)")
            return true
        } catch {
            Log.error(.capture, "Ses silinemedi: \(path)", error)
            return false
        }
    }

    enum ArchiveError: LocalizedError {
        case exportUnavailable, emptyOutput
        var errorDescription: String? {
            switch self {
            case .exportUnavailable: "Ses dönüştürücü kurulamadı."
            case .emptyOutput:       "Dönüştürülen dosya boş çıktı."
            }
        }
    }
}
