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
    /// Transkriptte adı verilmiş konuşmacılar. Davetlilerden ayrı gösterilir:
    /// bu ayrım toplantının kimin için yapıldığını söyler (DESIGN.md §4).
    var speakers: [String] = []
    /// Güç/termal nedeniyle ertelendiyse kullanıcı elle başlatabilir.
    var onSummarizeNow: (() -> Void)?
    var onToggleAction: ((MeetingAction) -> Void)?
    /// Konu başlığından transkriptteki yerine atlama.
    var onOpenTopic: ((TopicSegment) -> Void)?
    /// Bir özet maddesinin transkriptteki karşılığına atlama. Metnin
    /// transkriptte karşılığı bulunamazsa çağıran `nil` verir ve madde
    /// tıklanabilir olmaz (Segment.bestMatch).
    var openText: ((String) -> Void)?
    var canOpenText: ((String) -> Bool)?
    /// Ses diskte ama transkript yok — ham sesten yeniden işle.
    var onRetry: (() -> Void)?
    /// Özeti beğenmediyse kullanıcı yeniden ürettirir. Notun **sonunda** durur:
    /// önce okunur, sonra karar verilir (tepede şerit yok — DESIGN.md §4).
    var onResummarize: (() -> Void)?

    @State private var actionsExpanded = true

    /// Gösterilecek gerçek içerik var mı? **Not sayılmaz** — bir not tek
    /// başına kaldığında sayfanın tepesinde yalnız bir kart olarak durmasın,
    /// ortadaki boş durumun açıklaması olsun.
    private var hasContent: Bool {
        summary != nil || !topics.isEmpty || !actions.isEmpty
    }

    /// Boş durumdaki tek düğme. Yeniden deneme özetlemeden önce gelir:
    /// transkript yoksa özetlenecek bir şey de yoktur.
    private var emptyAction: (title: String, run: () -> Void)? {
        if let onRetry { return ("Yeniden dene", onRetry) }
        if let onSummarizeNow { return ("Şimdi özetle", onSummarizeNow) }
        return nil
    }

    var body: some View {
        if !hasContent {
            EmptyState(icon: onRetry == nil ? "sparkles" : "exclamationmark.arrow.circlepath",
                       title: onRetry == nil ? "Özet hazır değil"
                                             : "Bu toplantı yazıya dökülmedi",
                       detail: emptyDetail,
                       actionTitle: emptyAction?.title,
                       action: emptyAction?.run)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let notice {
                        Notice(text: notice, action: onSummarizeNow)
                    }
                    if !participants.isEmpty || !speakers.isEmpty {
                        PeopleStrip(invited: participants, speaking: speakers)
                    }
                    if !actions.isEmpty {
                        Section("Aksiyonlar", expanded: $actionsExpanded) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(actions) { action in
                                    ActionRow(action: action,
                                              onToggle: { onToggleAction?(action) },
                                              onOpen: opener(action.task))
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
                                        Bullet(text: madde, onOpen: opener(madde))
                                    }
                                }
                            }
                        }
                        if !summary.kararlar.isEmpty {
                            Section("Kararlar") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(summary.kararlar.enumerated()),
                                            id: \.offset) { _, karar in
                                        Bullet(text: karar, onOpen: opener(karar))
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
                                           onOpen: onOpenTopic.map { open in { open(topic) } },
                                           onOpenBullet: { madde in
                                               if let action = opener(madde) { action() }
                                               else { onOpenTopic?(topic) }
                                           })
                            }
                        }
                    }
                    if let onResummarize {
                        ResummarizeRow(action: onResummarize)
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

    /// Madde transkriptte bulunabiliyorsa açma eylemi, bulunamıyorsa `nil`.
    /// Tıklanabilirlik böylece **gerçek bir hedefe** bağlı olur.
    private func opener(_ text: String) -> (() -> Void)? {
        guard let openText, canOpenText?(text) ?? false else { return nil }
        return { openText(text) }
    }

    private var emptyDetail: String {
        if onRetry != nil { return "Ham ses kaydı duruyor." }
        return notice ?? "Özetleme kayıt bittikten sonra çalışır."
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

/// Notun sonundaki tek eylem: özeti yeniden ürettir.
///
/// Notun **altında** durur; kullanıcı önce okur, sonra beğenmediğine karar
/// verir. Tepede bir şerit ya da araç çubuğu düğmesi bu sırayı bozardı.
private struct ResummarizeRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 10))
                    Text("Özeti yeniden oluştur")
                        .font(.system(size: 12))
                }
                .foregroundStyle(isHovered ? Color.oraCarmine : Color.oraInkMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(OraStyle.transition) { isHovered = hovering }
            }
            .help("Aynı transkriptten yeni bir özet üretir")
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
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

/// Madde. Transkriptte karşılığı bulunabiliyorsa tıklanır ve oraya götürür;
/// göstergesi yalnızca imleç üzerindeyken beliren ok — sürekli duran bir simge
/// madde listesini ızgaraya çevirirdi (BRAND: dekoratif öğe yok).
private struct Bullet: View {
    let text: String
    var onOpen: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Color.oraInkMuted)
            // Eski satırlarda model artığı olabilir; yazım tarafı artık
            // temizliyor, gösterim tarafı geçmişi kurtarıyor.
            Text(MeetingStore.cleaned(text))
                .font(.system(size: 14))
                .lineSpacing(OraStyle.bodyLineSpacing - 1)
                .foregroundStyle(Color.oraInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if onOpen != nil, isHovered {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.oraInkMuted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { hovering in
            guard onOpen != nil else { return }
            withAnimation(OraStyle.transition) { isHovered = hovering }
        }
        .help(onOpen == nil ? "" : "Bu maddenin geçtiği yeri transkriptte aç")
    }
}

/// Bir konu: başlık + maddeler. Başlığa tıklamak transkriptte o ana götürür —
/// referans üründe olmayan, kaydı elinde tutmanın getirdiği yer.
private struct TopicBlock: View {
    let topic: TopicSegment
    var onOpen: (() -> Void)?
    /// Konunun maddeleri de tek tek transkripte bağlanır.
    var onOpenBullet: ((String) -> Void)?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(MeetingStore.cleaned(topic.title))
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
                    Bullet(text: madde, onOpen: onOpenBullet.map { open in { open(madde) } })
                }
            }
        }
    }
}

/// Katılımcılar. Renkli avatar yok — BRAND.md ikinci bir vurgu rengi açmıyor;
/// baş harfler krem daire üzerinde mürekkeple durur.
private struct PeopleStrip: View {
    /// Takvimden gelen davetliler.
    let invited: [String]
    /// Transkriptte adı verilmiş, yani gerçekten **konuşan** kişiler.
    let speaking: [String]

    /// Konuşanlar önce gelir; yalnızca davetli kalanlar `.oraInkMuted`
    /// okunur. Renk yerine **ton** farkı: yeni bir renk girmez ve "konuştu"
    /// bilgisini sessizce taşır.
    private var rows: [(name: String, spoke: Bool)] {
        let spoke = Set(speaking)
        return speaking.map { ($0, true) }
            + invited.filter { !spoke.contains($0) }.map { ($0, false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Kişiler")
            if !invited.isEmpty, !speaking.isEmpty {
                Text("davetli \(invited.count) · konuşan \(speaking.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
            }
            FlowLayout(spacing: 8) {
                ForEach(rows, id: \.name) { row in
                    HStack(spacing: 6) {
                        Text(Self.initials(row.name))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(row.spoke ? Color.oraInk : Color.oraInkMuted)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.oraChrome))
                        Text(row.name)
                            .font(.system(size: 13))
                            .foregroundStyle(row.spoke ? Color.oraInk : Color.oraInkMuted)
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
    /// İş cümlesine tıklamak transkriptte o ana götürür.
    var onOpen: (() -> Void)?
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
                Text(MeetingStore.cleaned(action.task))
                    .font(.system(size: 14))
                    .lineSpacing(OraStyle.bodyLineSpacing - 1)
                    .foregroundStyle(action.isDone ? Color.oraInkMuted : Color.oraInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let context = action.context, !MeetingStore.isUnspecified(context) {
                    Text(MeetingStore.cleaned(context))
                        .font(.system(size: 12))
                        .lineSpacing(OraStyle.bodyLineSpacing - 2)
                        .foregroundStyle(Color.oraInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            .help(onOpen == nil ? "" : "Bu işin konuşulduğu yeri transkriptte aç")

            if onOpen != nil, isHovered {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
                    .padding(.top, 2)
            }

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
        !MeetingStore.isUnspecified(person)
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
            if let deadline, !MeetingStore.isUnspecified(deadline) {
                Text(sentenceCased(MeetingStore.cleaned(deadline)))
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
