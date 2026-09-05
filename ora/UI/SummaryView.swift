import SwiftUI

/// Özet sekmesi.
///
/// Sıra Circleback referansından geliyor (`circleback-notes/`): **aksiyonlar
/// önce**, çünkü kullanıcının toplantı notuna ilk sorusu "bana ne düştü".
/// Ardından genel bakış, kararlar ve konu bölümleri.
///
/// Konuşma payı / ölü hava kartı **kaldırıldı** — referans çıktılarda karşılığı
/// yok ve okuma akışını kesiyordu; kanal başına iki kova zaten kişi bilgisi
/// taşımıyordu.
struct SummaryView: View {

    let summary: Ozet?
    let topics: [TopicSegment]
    let actions: [MeetingAction]
    let notice: String?
    /// Takvimden gelen katılımcılar. Takvim kapalıysa boş ve **yer tutmaz**.
    var participants: [String] = []
    /// Güç/termal nedeniyle ertelendiyse kullanıcı elle başlatabilir.
    var onSummarizeNow: (() -> Void)?
    var onToggleAction: ((MeetingAction) -> Void)?
    /// Konu başlığından transkriptteki yerine atlama.
    var onOpenTopic: ((TopicSegment) -> Void)?

    @State private var actionsExpanded = true

    private var isEmpty: Bool {
        summary == nil && notice == nil && topics.isEmpty && actions.isEmpty
    }

    var body: some View {
        if isEmpty {
            EmptyState(icon: "sparkles",
                       title: "Özet hazır değil",
                       detail: "Özetleme kayıt bittikten sonra çalışır.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let notice {
                        Notice(text: notice, action: onSummarizeNow)
                    }
                    if !participants.isEmpty {
                        PeopleStrip(names: participants)
                    }
                    if !actions.isEmpty {
                        Section("Aksiyonlar", expanded: $actionsExpanded) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(actions) { action in
                                    ActionRow(action: action) { onToggleAction?(action) }
                                }
                            }
                        }
                    }
                    if let summary {
                        if !summary.genelBakis.isEmpty {
                            Section("Genel bakış") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(summary.genelBakis.enumerated()),
                                            id: \.offset) { _, madde in
                                        Bullet(text: madde)
                                    }
                                }
                            }
                        }
                        if !summary.kararlar.isEmpty {
                            Section("Kararlar") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(summary.kararlar.enumerated()),
                                            id: \.offset) { _, karar in
                                        Bullet(text: karar)
                                    }
                                }
                            }
                        }
                    }
                    if !topics.isEmpty {
                        // Konular artık başlık listesi değil, notun gövdesi.
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(topics) { topic in
                                TopicBlock(topic: topic,
                                           onOpen: onOpenTopic.map { open in { open(topic) } })
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: OraStyle.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Bölüm etiketi — BRAND.md tipografi tablosu: 13 medium, uppercase,
    /// letter-spacing, `.oraInk`.
    @ViewBuilder
    private func Section<Content: View>(_ title: String,
                                        expanded: Binding<Bool>? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let expanded {
                Button {
                    withAnimation(OraStyle.transition) { expanded.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        SectionLabel(title)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.oraInkMuted)
                            .rotationEffect(.degrees(expanded.wrappedValue ? 0 : 180))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.wrappedValue ? "\(title) bölümünü kapat"
                                                          : "\(title) bölümünü aç")
                if expanded.wrappedValue { content() }
            } else {
                SectionLabel(title)
                content()
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .medium))
            .kerning(0.8)
            .foregroundStyle(Color.oraInk)
    }
}

private struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(OraStyle.bodyLineSpacing - 1)
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Bir konu: başlık + maddeler. Başlığa tıklamak transkriptte o ana götürür —
/// referans üründe olmayan, kaydı elinde tutmanın getirdiği yer.
private struct TopicBlock: View {
    let topic: TopicSegment
    var onOpen: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(topic.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.oraInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if onOpen != nil, isHovered {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            .onHover { hovering in
                guard onOpen != nil else { return }
                withAnimation(OraStyle.transition) { isHovered = hovering }
            }
            .help(onOpen == nil ? "" : "Transkriptte bu bölüme git")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(topic.bullets.enumerated()), id: \.offset) { _, madde in
                    Bullet(text: madde)
                }
            }
        }
    }
}

/// Katılımcılar. Renkli avatar yok — BRAND.md ikinci bir vurgu rengi açmıyor;
/// baş harfler krem daire üzerinde mürekkeple durur.
private struct PeopleStrip: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Kişiler")
            FlowLayout(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(Self.initials(name))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.oraInk)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.oraChrome))
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.oraInk)
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// "Merve Halilzade" → "MH". Türkçe locale şart: "ırmak" → "I" değil "İ" olmasın.
    static func initials(_ name: String) -> String {
        let turkish = Locale(identifier: "tr_TR")
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map { String($0).uppercased(with: turkish) } }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// Aksiyon satırı: onay kutusu · iş cümlesi · gerekçe · sahip çipi.
///
/// Gerekçe satırı ("Çağrı'nın talebi: …") maddeyi tek başına anlaşılır kılan
/// şeydir; referans çıktılarda her aksiyonun altında bir tane var.
private struct ActionRow: View {
    let action: MeetingAction
    var onToggle: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onToggle?() } label: {
                Image(systemName: action.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.monochrome)
                    // BRAND: onay/hazır Carmine — kayıt kırmızısı değil.
                    .foregroundStyle(action.isDone ? Color.oraCarmine : Color.oraInkMuted)
            }
            .buttonStyle(.plain)
            .disabled(onToggle == nil)
            .accessibilityLabel(action.isDone ? "Tamamlandı olarak işaretlendi"
                                              : "Tamamlandı olarak işaretle")

            VStack(alignment: .leading, spacing: 4) {
                Text(action.task)
                    .font(.system(size: 14))
                    .lineSpacing(OraStyle.bodyLineSpacing - 1)
                    .foregroundStyle(action.isDone ? Color.oraInkMuted : Color.oraInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let context = action.context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 12))
                        .lineSpacing(OraStyle.bodyLineSpacing - 2)
                        .foregroundStyle(Color.oraInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            OwnerChip(person: action.person, deadline: action.deadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oraQuietCard(hovered: isHovered)
        .onHover { hovering in
            withAnimation(OraStyle.transition) { isHovered = hovering }
        }
    }
}

/// Sahip ve varsa son tarih. Kişi belirtilmemişse çip **hiç çizilmez** —
/// "Atanan kişi: Belirtilmedi" satırı yer kaplayıp bilgi vermiyordu.
private struct OwnerChip: View {
    let person: String
    let deadline: String?

    private static let turkish = Locale(identifier: "tr_TR")

    private var isSpecified: Bool {
        person.lowercased(with: Self.turkish) != "belirtilmedi"
            && !person.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if isSpecified {
                HStack(spacing: 5) {
                    Text(PeopleStrip.initials(person))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.oraInk)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.oraChrome))
                    Text(sentenceCased(person))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInk)
                        .lineLimit(1)
                }
            }
            if let deadline, !deadline.isEmpty {
                Text(sentenceCased(deadline))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    /// Model alanları küçük harfle dönebiliyor. Türkçe locale ile büyütülür —
    /// aksi hâlde "i" → "I" olurdu.
    private func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased(with: Self.turkish) + value.dropFirst()
    }
}

/// Özet neden yok — sessiz başarısızlık yok.
private struct Notice: View {
    let text: String
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button("Şimdi özetle", action: action)
            }
        }
        .padding(12)
        .oraCard()
    }
}
