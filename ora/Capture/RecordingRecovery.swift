import Foundation

/// Yarım kalan bir kayıt: uygulama kayıt sürerken çöktüğünde diskte kalan WAV.
struct InterruptedRecording: Identifiable, Sendable {
    let url: URL
    let modified: Date
    let duration: TimeInterval
    var id: String { url.lastPathComponent }

    var meetingID: Int64? { Int64(url.deletingPathExtension().lastPathComponent) }
}

/// Çökme kurtarma.
///
/// Kayıt sürerken `{dosya}.wav.recording` işaretçisi diskte durur ve kayıt normal
/// bittiğinde silinir. Açılışta kalan her işaretçi, yarım kalmış bir kayıt demektir.
/// Ses zaten artımlı yazıldığı için dosyanın **içeriği sağlamdır**; yalnızca son
/// flush'tan sonraki başlık alanları eksik kalmış olabilir — onarılır.
enum RecordingRecovery {

    /// Açılışta bir kez çağrılır. Yarım kalan kayıtları bulur ve başlıklarını onarır.
    static func scan() -> [InterruptedRecording] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: AppPaths.recordings,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }

        let markers = entries.filter { $0.lastPathComponent.hasSuffix(StereoRecordingWriter.markerSuffix) }
        var found: [InterruptedRecording] = []

        for marker in markers {
            let path = marker.path(percentEncoded: false)
            let audioPath = String(path.dropLast(StereoRecordingWriter.markerSuffix.count))
            let audioURL = URL(fileURLWithPath: audioPath)

            guard manager.fileExists(atPath: audioPath) else {
                try? manager.removeItem(at: marker)
                continue
            }
            do {
                let duration = try repairHeader(at: audioURL)
                // Bir saniyeden kısa artıklar kullanıcıya sorulmaya değmez.
                guard duration >= 1 else {
                    try? manager.removeItem(at: audioURL)
                    try? manager.removeItem(at: marker)
                    Log.info(.capture, "Yarım kayıt çok kısaydı, silindi: \(audioURL.lastPathComponent)")
                    continue
                }
                let modified = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
                found.append(InterruptedRecording(url: audioURL, modified: modified,
                                                  duration: duration))
                Log.warning(.capture, "Yarım kalan kayıt bulundu: \(audioURL.lastPathComponent) "
                            + String(format: "(%.1f sn)", duration))
            } catch {
                Log.error(.capture, "Yarım kayıt onarılamadı: \(audioURL.lastPathComponent)", error)
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// Kullanıcı "sakla" derse: işaretçi silinir, dosya normal bir kayda dönüşür.
    static func keep(_ recording: InterruptedRecording) {
        let marker = URL(fileURLWithPath: recording.url.path(percentEncoded: false)
                         + StereoRecordingWriter.markerSuffix)
        try? FileManager.default.removeItem(at: marker)
        Log.info(.capture, "Yarım kayıt saklandı: \(recording.url.lastPathComponent)")
    }

    /// Kullanıcı "sil" derse: ses dosyası ve işaretçi birlikte gider.
    static func discard(_ recording: InterruptedRecording) {
        let marker = URL(fileURLWithPath: recording.url.path(percentEncoded: false)
                         + StereoRecordingWriter.markerSuffix)
        try? FileManager.default.removeItem(at: recording.url)
        try? FileManager.default.removeItem(at: marker)
        Log.info(.capture, "Yarım kayıt silindi: \(recording.url.lastPathComponent)")
    }

    /// RIFF/data boyutlarını dosyanın gerçek uzunluğuna göre yeniden yazar.
    /// Dönüş: saniye cinsinden süre.
    @discardableResult
    private static func repairHeader(at url: URL) throws -> TimeInterval {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let total = try handle.seekToEnd()
        guard total > 44 else { return 0 }
        let dataBytes = UInt32(total - 44)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: StereoRecordingWriter.header(dataByteCount: dataBytes))
        try handle.synchronize()

        let frames = Double(dataBytes) / Double(RecordingFormat.bytesPerFrame)
        return frames / RecordingFormat.sampleRate
    }
}
