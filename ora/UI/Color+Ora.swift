import SwiftUI
import AppKit

// MARK: - BRAND.md paleti
//
// Renkler `Resources/Assets.xcassets/Colors` içinde **bir kez** tanımlıdır.
// `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` açık olduğu için
// Xcode her renk kümesi için derleme zamanında `Color.oraPaper`, `NSColor.oraPaper`
// ve `ColorResource.oraPaper` sembollerini üretir — elle string yazılmaz, yanlış
// isim derlenmez.
//
// | Rol                      | Hex       | Token          |
// |--------------------------|-----------|----------------|
// | Kağıt — ana tuval        | #FAF6F0   | .oraPaper      |
// | Kağıt — kenar şerit      | #F3ECE1   | .oraChrome     |
// | Nötr vurgu / hover       | #F5F5F7   | .oraGray       |
// | Metin & tipografi        | #333333   | .oraInk        |
// | İkincil metin            | #888888   | .oraInkMuted   |
// | Vurgu                    | #1A56A3   | .oraBlue       |
// | Seçili arka plan         | #EEF3FB   | .oraBlueSoft   |
// | Kayıt durumu             | #E53935   | .oraRed        |
// | Kart / panel içi         | #FFFFFF   | .oraSurface    |
// | Kenarlık                 | #E8E8E8   | .oraBorder     |
//
// Görünümlerde ham hex veya `Color(red:green:blue:)` yazılmaz (CLAUDE.md kural #8).
// `.oraRed` yalnızca kayıt butonu ve menü bar noktası içindir (kural #9).

/// Paletin tamamı — testler ve doğrulama için tek listede.
enum OraPalette {
    static let all: [ColorResource] = [
        .oraPaper, .oraChrome, .oraGray, .oraInk, .oraInkMuted,
        .oraBlue, .oraBlueSoft, .oraRed, .oraSurface, .oraBorder,
    ]
}

/// BRAND.md'nin izin verdiği tek gölge, tek köşe yarıçapı ve tek geçiş süresi.
enum OraStyle {
    /// Köşe yarıçapı en fazla 8.
    static let cornerRadius: CGFloat = 8
    static let shadowColor = Color.black.opacity(0.08)
    static let shadowRadius: CGFloat = 3
    static let shadowOffsetY: CGFloat = 1
    /// Geçişler en fazla 150 ms.
    static let transition = Animation.easeOut(duration: 0.15)
}

extension View {
    /// BRAND.md'de tanımlı tek gölge. Başka gölge yazılmaz.
    func oraShadow() -> some View {
        shadow(color: OraStyle.shadowColor,
               radius: OraStyle.shadowRadius,
               y: OraStyle.shadowOffsetY)
    }

    /// Kart yüzeyi: beyaz zemin, ince kenarlık, 8 köşe.
    func oraCard() -> some View {
        background(Color.oraSurface)
            .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius)
                    .stroke(Color.oraBorder, lineWidth: 1)
            )
    }
}
