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
            // sessiz bekleme yok).
            Text(stageName)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var percent: Int? {
        switch stage {
        case .downloadingLanguage(let value), .transcribing(let value),
             .punctuating(let value), .summarizing(let value):
            Int((value * 100).rounded())
        case .preparingLanguage, .idle, .done:
            nil
        }
    }

    private var percentText: String? { percent.map { "%\($0)" } }

    private var stageName: String {
        switch stage {
        case .preparingLanguage:   "Dil hazırlanıyor"
        case .downloadingLanguage: "Dil paketi indiriliyor"
        case .transcribing:        "Yazıya dökülüyor"
        case .punctuating:         "Noktalama ekleniyor"
        case .summarizing:         "Özetleniyor"
        case .idle, .done:         ""
        }
    }

    private var spokenLabel: String {
        stageName + (percent.map { " · yüzde \($0)" } ?? "")
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

#Preview("İşlem durumu") {
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
