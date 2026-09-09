import AVFoundation

/// `AVAudioConverter`ın **tek seferlik** girdi kaynağı.
///
/// Örnekleme oranı dönüşümü blok formunu zorunlu kılar
/// (`convert(to:error:withInputFrom:)`) ve blok **iki kez** çağrılır: bir kez
/// tamponu vermek, bir kez "veri kalmadı" demek için. Bu yüzden bir bayrak
/// gerekiyor — bayrağı silerek uyarıdan kurtulmak mümkün değil.
///
/// Swift bu bloğu `@Sendable` görüyor ve eskiden iki çağrı yerinde de
/// "eşzamanlı koşan kodda değişken yakalandı" + "Sendable olmayan
/// `AVAudioPCMBuffer` yakalandı" diye uyarıyordu. Uyarının varsayımı ölçüldü
/// (RESEARCH.md §31): blok **çağıranın şeridinde** ve `convert` dönmeden
/// **önce** koşuyor; arka plan kuyruğundan çağrıldığında da öyle, dönüşten
/// sonra tek çağrı yok. Eşzamanlılık yok, uyarı yanlış pozitifti.
/// `@unchecked Sendable` burada o güvencenin yazıya dökülmüş hâli — ve
/// `oraTests/AudioConversionTests` güvence bozulursa haber verir.
///
/// **Paylaşılmaz:** her dönüşüm kendi örneğini kurar, örnek çağrıyı aşmaz.
nonisolated final class SingleShotInput: @unchecked Sendable {

    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    /// `AVAudioConverterInputBlock` gövdesi.
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
