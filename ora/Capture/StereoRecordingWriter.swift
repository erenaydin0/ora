import Foundation

/// Kaydın disk formatı.
///
/// 16 kHz / 16 bit / stereo seçildi: `DictationTranscriber` zaten konuşma bandında
/// çalışıyor (RESEARCH.md §2 ölçümü 16 kHz ses ile yapıldı) ve bu oran saatte
/// ~230 MB tutuyor. 48 kHz'te aynı kayıt ~690 MB olurdu; konuşma için karşılığı
/// olmayan bir üç kat.
enum RecordingFormat {
    static let sampleRate: Double = 16_000
    static let channelCount = 2
    static let bitsPerSample = 16
    static let bytesPerFrame = channelCount * bitsPerSample / 8   // 4
}

/// Artımlı stereo WAV yazıcısı — ch0 = mikrofon, ch1 = sistem sesi.
///
/// Kural #12: ses hiçbir zaman tamamı RAM'de tutulmaz. Bellekte yalnızca
/// henüz diske inmemiş son ~1 saniyelik pencere durur.
/// Kural #11: kanallar karıştırılmaz; kısa kalan kanal sessizlikle doldurulur,
/// kırpılmaz — bu, örneklerin **mutlak frame konumuna** yazılmasıyla sağlanır.
///
/// Yazım kendi seri kuyruğunda yapılır. Ses geri çağrıları buraya kopyalayıp
/// döner; disk beklemesi ses yoluna asla yansımaz.
final class StereoRecordingWriter: @unchecked Sendable {

    /// Kayıt sürerken duran işaretçi dosya. Uygulama çökerse diskte kalır ve
    /// açılışta yarım kayıt olarak bulunur.
    static let markerSuffix = ".recording"

    private let url: URL
    private let markerURL: URL
    private let queue = DispatchQueue(label: "ora.capture.writer", qos: .userInitiated)

    private var handle: FileHandle
    /// Diske yazılmış frame sayısı — bekleyen dizilerin sıfırıncı elemanı bu frame'dir.
    private var baseFrame: Int64 = 0
    /// Kanal başına bekleyen örnekler, `baseFrame`'den itibaren hizalı.
    private var pending: [[Float]] = [[], []]
    /// Alınan en ileri frame konumu.
    private var highWater: Int64 = 0
    /// Diske çoktan yazılmış bir konuma geç gelen ve düşürülen frame sayısı.
    private(set) var lateFrames: Int64 = 0
    private var firstWriteError: Error?

    init(url: URL) throws {
        self.url = url
        self.markerURL = URL(fileURLWithPath: url.path(percentEncoded: false)
                             + Self.markerSuffix)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path(percentEncoded: false)) {
            try manager.removeItem(at: url)
        }
        manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        manager.createFile(atPath: markerURL.path(percentEncoded: false), contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataByteCount: 0))
    }

    // MARK: - Ses yolundan çağrılanlar

    /// `frameIndex`: kaydın başlangıcına göre **mutlak** frame konumu.
    /// Buffer sayısına göre değil, host time damgasına göre hesaplanır.
    func append(_ channel: Channel, frames: [Float], at frameIndex: Int64) {
        queue.async { [self] in place(channel, frames, frameIndex) }
    }

    /// Saniyede bir çağrılır. `limitFrame`'e kadar olan her şey diske iner;
    /// o ana kadar gelmemiş örnekler sessizlik olarak yazılır.
    func flush(upTo limitFrame: Int64) {
        queue.async { [self] in writeOut(upTo: limitFrame) }
    }

    // MARK: - Sorgu

    /// Diske yazılmış sürenin saniye karşılığı.
    var writtenDuration: TimeInterval {
        queue.sync { Double(baseFrame) / RecordingFormat.sampleRate }
    }

    /// Yazım sırasında oluşan ilk hata — kayıt sonunda kullanıcıya ulaşır.
    var pendingError: Error? { queue.sync { firstWriteError } }

    // MARK: - Bitiş

    /// Kalan her şeyi yazar, başlığı günceller, işaretçiyi siler.
    func finish() throws -> URL {
        try queue.sync {
            writeOut(upTo: highWater)
            try handle.synchronize()
            try handle.close()
            try? FileManager.default.removeItem(at: markerURL)
            if let firstWriteError { throw OraError.audioWriteFailed(underlying: firstWriteError) }
            return url
        }
    }

    // MARK: - Uygulama (hepsi `queue` üstünde)

    private func place(_ channel: Channel, _ frames: [Float], _ frameIndex: Int64) {
        guard !frames.isEmpty else { return }
        var start = frameIndex
        var slice = frames[frames.startIndex...]

        // Diske inmiş bir konuma geç gelen örnekler kurtarılamaz; sayılır ve düşer.
        if start < baseFrame {
            let skip = Int(min(Int64(frames.count), baseFrame - start))
            lateFrames += Int64(skip)
            slice = frames[(frames.startIndex + skip)...]
            start = baseFrame
            guard !slice.isEmpty else { return }
        }

        let lane = channel.rawValue
        let offset = Int(start - baseFrame)
        let needed = offset + slice.count
        if pending[lane].count < needed {
            pending[lane].append(contentsOf:
                repeatElement(0, count: needed - pending[lane].count))
        }
        var index = offset
        for sample in slice {
            pending[lane][index] = sample
            index += 1
        }
        highWater = max(highWater, start + Int64(slice.count))
    }

    private func writeOut(upTo limitFrame: Int64) {
        let end = max(baseFrame, min(limitFrame, highWater))
        let count = Int(end - baseFrame)
        guard count > 0, firstWriteError == nil else { return }

        var interleaved = [Int16](repeating: 0, count: count * RecordingFormat.channelCount)
        let mic = pending[Channel.mic.rawValue]
        let system = pending[Channel.system.rawValue]
        for frame in 0 ..< count {
            interleaved[frame * 2]     = Self.pcm(frame < mic.count ? mic[frame] : 0)
            interleaved[frame * 2 + 1] = Self.pcm(frame < system.count ? system[frame] : 0)
        }

        do {
            try interleaved.withUnsafeBufferPointer { buffer in
                try handle.write(contentsOf: Data(buffer: buffer))
            }
            baseFrame = end
            for lane in pending.indices {
                pending[lane].removeFirst(min(count, pending[lane].count))
            }
            try updateHeader()
        } catch {
            firstWriteError = error
            Log.error(.capture, "WAV yazımı başarısız", error)
        }
    }

    /// Başlığı her flush'ta günceller — çökme hâlinde dosya en fazla 1 saniye
    /// eksik başlıkla kalır, `RecordingRecovery` onu da onarır.
    private func updateHeader() throws {
        let dataBytes = UInt32(baseFrame * Int64(RecordingFormat.bytesPerFrame))
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataByteCount: dataBytes))
        try handle.seek(toOffset: end)
    }

    private static func pcm(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32_767)
    }

    // MARK: - WAV başlığı

    static func header(dataByteCount: UInt32) -> Data {
        let channels = UInt16(RecordingFormat.channelCount)
        let bits = UInt16(RecordingFormat.bitsPerSample)
        let rate = UInt32(RecordingFormat.sampleRate)
        let blockAlign = channels * bits / 8
        let byteRate = rate * UInt32(blockAlign)

        var data = Data(capacity: 44)
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        put("RIFF")
        put32(36 &+ dataByteCount)
        put("WAVE")
        put("fmt ")
        put32(16)                 // PCM alt yığın boyutu
        put16(1)                  // PCM
        put16(channels)
        put32(rate)
        put32(byteRate)
        put16(blockAlign)
        put16(bits)
        put("data")
        put32(dataByteCount)
        return data
    }
}
