import SwiftUI

/// Boş durum bloğu. Dekoratif öğe yok, tek SF Symbol + iki satır metin.
///
/// Çıkmaz sokak bırakmamak için isteğe bağlı **tek** bir düğme alır ve düğme
/// metnin altında, blokla birlikte ortalanır — kullanıcının yapabileceği şey
/// durumun yanında durmalı, ekranın tepesinde bir şeritte değil.
struct EmptyState: View {

    let icon: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.oraInkMuted)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// İşlem sürerken görünen durum. Boş durumla **aynı iskelet**: simge yerine
/// eğri, başlık yerine yüzde, açıklama yerine aşamanın Türkçe adı.
///
/// Üstteki ilerleme çubuğunun yerini aldı. Çubuk hem içeriğin üstünde yatay bir
/// dikiş bırakıyordu hem de asıl beklenen şey (özet) ekranın ortasında "hazır
/// değil" derken ilgisiz bir yerde duruyordu.
struct ProcessingState: View {

    let stage: RecordingController.Stage

    /// Dönen metin kaç saniyede bir değişsin.
    private static let rotation: TimeInterval = 3.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            CurveLoader()
                .padding(.bottom, 4)
            if let percentText {
                Text(percentText)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.oraInk)
                    .contentTransition(.numericText())
                    .animation(OraStyle.transition, value: percentText)
            }
            // İlk parça bitene kadar yüzde uzun süre %0'da kalıyor; o sırada
            // ne olduğunu söyleyen tek şey bu satır (CLAUDE.md, Hata Yönetimi:
            // sessiz bekleme yok). Aşamanın birden çok gerçek adımı varsa
            // metin bunlar arasında dönüyor — bekleme donmuş hissettirmesin.
            TimelineView(.periodic(from: .now, by: Self.rotation)) { timeline in
                Text(message(at: timeline.date))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(OraStyle.transition, value: message(at: timeline.date))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var percent: Int? {
        switch stage {
        case .importing(let value), .downloadingLanguage(let value),
             .transcribing(let value), .punctuating(let value), .summarizing(let value):
            Int((value * 100).rounded())
        case .preparingLanguage, .idle, .done:
            nil
        }
    }

    private var percentText: String? { percent.map { "%\($0)" } }

    /// Aşamanın **gerçekten yaptığı** adımlar. Uydurma değil: noktalama adımı
    /// büyük harfi de düzeltiyor, özetleme adımı sırayla konu, aksiyon ve
    /// karar üretiyor. Bekleyen kullanıcıya yanlış bilgi verilmez.
    private var messages: [String] {
        switch stage {
        case .importing:
            ["Ses dosyası hazırlanıyor", "Tek kanala indiriliyor"]
        case .preparingLanguage:
            ["Dil hazırlanıyor", "Model yükleniyor"]
        case .downloadingLanguage:
            ["Dil paketi indiriliyor"]
        case .transcribing:
            ["Yazıya dökülüyor", "Ses çözümleniyor", "Kelimeler zamanlanıyor"]
        case .punctuating:
            ["Noktalama ekleniyor", "Cümleler ayrılıyor", "Büyük harfler düzeltiliyor"]
        case .summarizing:
            ["Özetleniyor", "Konular ayrıştırılıyor", "Aksiyonlar çıkarılıyor",
             "Kararlar toparlanıyor", "Cümleler düzeltiliyor"]
        case .idle, .done:
            [""]
        }
    }

    /// Hareket azaltma açıkken metin dönmez; ilk adım sabit kalır.
    private func message(at date: Date) -> String {
        guard !reduceMotion, messages.count > 1 else { return messages[0] }
        let tick = Int(date.timeIntervalSinceReferenceDate / Self.rotation)
        return messages[abs(tick) % messages.count]
    }

    private var spokenLabel: String {
        // VoiceOver dönen metni okumaz — sürekli değişen bir etiket okumayı
        // böler. Aşamanın kanonik adı okunur.
        messages[0] + (percent.map { " · yüzde \($0)" } ?? "")
    }
}

#Preview("Boş durum · düğmesiz") {
    EmptyState(icon: "sparkles",
               title: "Özet hazır değil",
               detail: "Özetleme kayıt bittikten sonra çalışır.")
        .frame(width: 620, height: 420)
        .background(Color.oraPaper)
}

#Preview("Boş durum · yeniden dene") {
    EmptyState(icon: "exclamationmark.arrow.circlepath",
               title: "Bu toplantı yazıya dökülmedi",
               detail: "Ham ses kaydı duruyor.",
               actionTitle: "Yeniden dene") { }
        .frame(width: 620, height: 420)
        .background(Color.oraPaper)
}

#Preview("İşlem durumu · dönen metin") {
    VStack(spacing: 0) {
        ProcessingState(stage: .punctuating(0.33))
        Divider().overlay(Color.oraBorder)
        ProcessingState(stage: .summarizing(0.81))
        Divider().overlay(Color.oraBorder)
        ProcessingState(stage: .preparingLanguage)
    }
    .frame(width: 620, height: 720)
    .background(Color.oraPaper)
}
