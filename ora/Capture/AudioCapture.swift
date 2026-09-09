import Foundation
import AVFoundation

/// Bir kaynağın frame konumunu takip eden hizalayıcı.
/// Her örnek yalnızca kendi kaynağının iş parçacığından çağrılır.
nonisolated private final class SourceAligner: @unchecked Sendable {
    private var anchor = FrameAnchor()
    private var lastLoggedResync = 0

    func position(hostTime: UInt64, start: UInt64, frames: Int, channel: Channel) -> Int64 {
        let position = anchor.position(hostTime: hostTime, start: start, producing: frames)
        if anchor.resyncCount > lastLoggedResync {
            lastLoggedResync = anchor.resyncCount
            Log.debug(.capture, "\(channel.databaseValue) kanalı saate yeniden çapalandı "
                      + "(\(anchor.resyncCount). kez)")
        }
        return position
    }
}

/// Kayıt hattının Capture katmanı.
///
/// Sözleşme (ARCHITECTURE.md): ses yazımı **birincil iştir**. Sistem sesi
/// alınamazsa kayıt durmaz, yalnız-mikrofon moduna düşer. Canlı transkripsiyon
/// `liveBuffers` üzerinden **ikincil** tüketicidir ve geri kalırsa buffer düşürülür.
nonisolated final class AudioCapture: AudioCapturing, @unchecked Sendable {

    /// Diske yazımın ses akışının kaç saniye gerisinden gittiği.
    /// Bu pencere, geç gelen buffer'ların hâlâ doğru frame konumuna
    /// yazılabilmesi için bırakılan paydır.
    private static let writeLag: TimeInterval = 0.5
    private static let flushInterval: TimeInterval = 1.0
    /// Kapsamlı tap'in sessizliğinin "kimse konuşmuyor" değil "yanlış süreci
    /// hedefliyoruz" demek olduğuna karar vermeden önce beklenen süre.
    private static let scopedTapGrace: TimeInterval = 3.0
    /// Global tap'e düştükten sonra da ses gelmiyorsa kullanıcıya söylenir.
    private static let silentTapWarning: TimeInterval = 12.0
    private static let silentTapReason = "Sistem sesi yakalanamıyor" 

    private let lock = NSLock()
    private let microphone = MicrophoneCapture()
    private let tap = SystemAudioTap()

    private var writer: StereoRecordingWriter?
    private var startHostTime: UInt64 = 0
    private var flushTimer: DispatchSourceTimer?
    private var currentURL: URL?
    private var micOnlyReason: String?
    private var tapIsActive = false
    private var scopeChecked = false
    private let timerQueue = DispatchQueue(label: "ora.capture.flush", qos: .utility)

    private let stateContinuation: AsyncStream<CaptureState>.Continuation
    let state: AsyncStream<CaptureState>
    private let liveContinuation: AsyncStream<LiveBuffer>.Continuation
    let liveBuffers: AsyncStream<LiveBuffer>

    init() {
        (state, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        // Tüketici geri kalırsa en yeni buffer'lar tutulur, eskiler DÜŞER —
        // diske yazım hiçbir koşulda beklemez.
        (liveBuffers, liveContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        stateContinuation.yield(.idle)
    }

    // MARK: - Başlat

    func start(meetingID: Int64, preferredApp: String? = nil) async throws {
        guard await MicrophoneCapture.requestAccess() else {
            let error = OraError.permissionDenied(.microphone)
            stateContinuation.yield(.failed(error))
            throw error
        }

        let url = AppPaths.recording(meetingID: meetingID)
        let writer: StereoRecordingWriter
        do {
            writer = try StereoRecordingWriter(url: url)
        } catch {
            let wrapped = OraError.audioWriteFailed(underlying: error)
            stateContinuation.yield(.failed(wrapped))
            throw wrapped
        }

        let start = AudioClock.now
        lock.withLock {
            self.writer = writer
            self.currentURL = url
            self.startHostTime = start
            self.micOnlyReason = nil
        }

        let micAligner = SourceAligner()
        let systemAligner = SourceAligner()

        do {
            try microphone.start { [weak self] frames, hostTime in
                self?.receive(.mic, frames, hostTime, micAligner)
            }
        } catch {
            _ = try? writer.finish()
            try? FileManager.default.removeItem(at: url)
            lock.withLock { self.writer = nil; self.currentURL = nil }
            let wrapped = error as? OraError ?? .audioWriteFailed(underlying: error)
            stateContinuation.yield(.failed(wrapped))
            throw wrapped
        }

        // Sistem sesi en iyi çabadır: alınamazsa kayıt yalnız mikrofonla sürer.
        do {
            try tap.start(preferredApp: preferredApp) { [weak self] frames, hostTime in
                self?.receive(.system, frames, hostTime, systemAligner)
            }
            lock.withLock { tapIsActive = true; scopeChecked = false }
        } catch {
            let reason = (error as? OraError)?.turkishMessage ?? error.localizedDescription
            lock.withLock { micOnlyReason = "Sistem sesi yakalanamadı" }
            lock.withLock { tapIsActive = false }
            Log.warning(.capture, "Sistem sesi tap'i açılamadı, yalnız-mikrofon moduna "
                        + "düşüldü: \(reason)")
        }

        startFlushTimer()
        emitState()
        Log.info(.capture, "Kayıt başladı — \(url.lastPathComponent)")
    }

    // MARK: - Durdur

    func stop() async throws -> URL {
        flushTimer?.cancel()
        flushTimer = nil
        microphone.stop()
        tap.stop()

        let writer = lock.withLock { self.writer }
        guard let writer else {
            stateContinuation.yield(.idle)
            throw OraError.audioWriteFailed(underlying: CocoaError(.fileNoSuchFile))
        }

        defer {
            lock.withLock {
                self.writer = nil
                self.currentURL = nil
                self.startHostTime = 0
                self.micOnlyReason = nil
            }
            stateContinuation.yield(.idle)
        }

        do {
            let finished = try writer.finish()
            if writer.lateFrames > 0 {
                Log.warning(.capture, "\(writer.lateFrames) frame diske yazılmış konuma "
                            + "geç geldi ve düşürüldü")
            }
            Log.info(.capture, "Kayıt bitti — \(finished.lastPathComponent), "
                     + String(format: "%.1f sn", writer.writtenDuration))
            // Sistem kanalının neden boş kaldığı sonradan tartışılmasın:
            // tap'in gerçekten frame verip vermediği ve sesin duyulur olup
            // olmadığı kayda geçer (RESEARCH.md §28.4).
            Log.info(.capture, "Sistem sesi tap'i — kapsam: \(tap.scopeDescription), "
                     + "\(tap.framesReceived) frame, tepe "
                     + String(format: "%.4f", tap.peakReceived))
            return finished
        } catch {
            let wrapped = error as? OraError ?? .audioWriteFailed(underlying: error)
            stateContinuation.yield(.failed(wrapped))
            throw wrapped
        }
    }

    // MARK: - Ses yolundan gelen

    private func receive(_ channel: Channel, _ frames: [Float],
                         _ hostTime: UInt64, _ aligner: SourceAligner) {
        let (writer, start) = lock.withLock { (self.writer, self.startHostTime) }
        guard let writer, start != 0 else { return }

        let position = aligner.position(hostTime: hostTime, start: start,
                                        frames: frames.count, channel: channel)
        writer.append(channel, frames: frames, at: position)
        yieldLive(channel, frames, position)
    }

    /// Canlı transkripsiyon tüketicisi (Faz 3). Tüketici yoksa veya geri kaldıysa
    /// buffer'lar akışın tampon politikası gereği düşer.
    private func yieldLive(_ channel: Channel, _ frames: [Float], _ position: Int64) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: RecordingFormat.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames.count)),
              let channelData = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { channelData.update(from: $0.baseAddress!, count: frames.count) }
        liveContinuation.yield(LiveBuffer(channel: channel, buffer: buffer,
                                          time: Double(position) / RecordingFormat.sampleRate))
    }

    // MARK: - Flush ve durum

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushTick()
        }
        timer.resume()
        flushTimer = timer
    }

    private func flushTick() {
        let (writer, start) = lock.withLock { (self.writer, self.startHostTime) }
        guard let writer, start != 0 else { return }
        let nowFrame = AudioClock.frameIndex(hostTime: AudioClock.now, start: start,
                                             sampleRate: RecordingFormat.sampleRate)
        let lag = Int64(Self.writeLag * RecordingFormat.sampleRate)
        writer.flush(upTo: nowFrame - lag)
        checkScopedTap(elapsed: Double(nowFrame) / RecordingFormat.sampleRate)
        emitState()
    }

    /// Kapsamlı tap sessizse ve sistemde başka bir şey ses çalıyorsa,
    /// hedeflediğimiz bundle ID sesi üretmiyordur (Electron/tarayıcı yardımcı
    /// süreçleri) — global tap'e geçilir. Global tap de sessiz kalıyorsa
    /// **kullanıcıya söylenir**: sessizce boş kanal kaydetmek bir toplantı
    /// kaydedicisi için kabul edilemez bir hata modudur.
    ///
    /// Ölçüt **genliktir, frame sayısı değil** (RESEARCH.md §28.4): tap sessiz
    /// frame de üretebiliyor; frame sayan gözcü o zaman "akıyor" sanıp boş
    /// kanalı sessizce kaydediyordu.
    private func checkScopedTap(elapsed: TimeInterval) {
        guard lock.withLock({ tapIsActive }) else { return }

        // **Ölçüt frame'dir, genlik değil.** Genliğe bakmak cazip ama yanlış:
        // toplantıda kimse konuşmuyorken hedef uygulama sessizdir, oysa tap
        // doğru bağlanmıştır. Frame akmıyorsa tap hiçbir şeye bağlanmamış
        // demektir — ayırt eden budur. Genlik yalnızca **günlüğe** yazılır
        // (RESEARCH.md §28.4).
        if tap.framesReceived > 0 {
            lock.withLock {
                scopeChecked = true
                if micOnlyReason == Self.silentTapReason { micOnlyReason = nil }
            }
            return
        }
        // Sistemde hiç ses çalmıyorsa frame gelmemesi doğrudur.
        guard SystemAudioTap.systemIsProducingOutput() else { return }

        let checked = lock.withLock { scopeChecked }
        if !checked, case .apps = tap.scope, elapsed >= Self.scopedTapGrace {
            lock.withLock { scopeChecked = true }
            tap.fallBackToGlobal()
            return
        }
        // Global tap'te frame hiç gelmiyorsa gerçek arıza: global tap kendimiz
        // hariç her şeyi yakalar. Kullanıcı bunu kayıt sürerken bilmeli.
        if case .globalExcludingSelf = tap.scope, elapsed >= Self.silentTapWarning {
            lock.withLock { micOnlyReason = Self.silentTapReason }
        }
    }

    private func emitState() {
        let (start, reason) = lock.withLock { (self.startHostTime, self.micOnlyReason) }
        guard start != 0 else { return }
        let elapsed = AudioClock.seconds(from: start, to: AudioClock.now)
        if let reason {
            stateContinuation.yield(.micOnly(reason: reason, elapsed: elapsed))
        } else {
            stateContinuation.yield(.recording(elapsed: elapsed))
        }
    }
}
