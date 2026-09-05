import SwiftUI

/// Transkript listesi. Kesinleşmemiş canlı metin `.oraInkMuted` ile gösterilir —
/// bu ton farkı, canlı sonucun bir **ön izleme** olduğunu ve kayıt sonrası tam
/// geçişte değişebileceğini söyler (DESIGN.md §4).
struct TranscriptView: View {

    let segments: [Segment]
    var volatileText: [Int: String] = [:]
    var notice: String?
    /// Özet'teki konu başlığından gelen atlama hedefi (saniye). Kaydırma
    /// yapıldıktan sonra `nil`'e çekilir ki aynı konuya tekrar basılabilsin.
    var jumpTarget: Binding<TimeInterval?> = .constant(nil)
    /// Kaydın sesi. Nil ise (canlı mod, sesi silinmiş toplantı) satırlar
    /// çalınamaz ve vurgulanmaz.
    var playback: AudioPlayback?
    /// Ses diskte ama transkript yok — boş durumdaki tek çıkış yolu.
    var onRetry: (() -> Void)?
    /// Nil ise düzeltme kapalıdır (canlı modda düzeltme yapılmaz).
    var onCorrect: ((Segment, String) -> Void)?
    /// Satırı silme ve konuşmacı etiketini değiştirme — düzeltmeyle aynı koşula
    /// bağlıdır (kayıt ve işlem sürerken kapalı).
    var onDelete: ((Segment) -> Void)?
    var onRelabel: ((Segment, String) -> Void)?
    /// Toplantı içi arama (⌘F). Kenar çubuğundaki arama toplantı **bulur**;
    /// bu arama bulunan toplantının içinde gezdirir.
    var find: Binding<String> = .constant("")
    var isFinding: Binding<Bool> = .constant(false)

    @State private var editing: Segment.ID?
    @State private var draft = ""
    @State private var matchIndex = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        if segments.isEmpty && volatileText.isEmpty {
            EmptyState(icon: onRetry == nil ? "text.alignleft"
                                            : "exclamationmark.arrow.circlepath",
                       title: "Transkript yok",
                       detail: onRetry == nil
                           ? "Kayıt sırasında canlı transkript burada akar."
                           : "Ham ses kaydı duruyor.",
                       actionTitle: onRetry == nil ? nil : "Yeniden dene",
                       action: onRetry)
        } else {
            transcript
                // Arama **yüzen** bir paneldir: sayfa genişliğinde bir şerit
                // okuma alanını bölüyordu, oysa arama geçici bir araçtır.
                .overlay(alignment: .topTrailing) {
                    if isFinding.wrappedValue {
                        findPanel
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                            .transition(.opacity)
                    }
                }
                .animation(OraStyle.transition, value: isFinding.wrappedValue)
        }
    }

    /// ⌘F paneli. Escape kapatır, Enter sonraki eşleşmeye gider.
    private var findPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
            TextField("Bu transkriptte ara", text: find)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInk)
                .frame(width: 150)
                .focused($findFocused)
                .onSubmit { step(1) }
            if !find.wrappedValue.isEmpty {
                Text(matches.isEmpty ? "eşleşme yok"
                                     : "\(matchIndex + 1)/\(matches.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.oraInkMuted)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help("Önceki eşleşme")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help("Sonraki eşleşme")
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Aramayı kapat")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.oraInkMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.oraSurface)
        .clipShape(RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .stroke(Color.oraBorder, lineWidth: 1))
        .oraShadow()
        .fixedSize()
        .onAppear { findFocused = true }
        .onExitCommand(perform: closeFind)
    }

    private var transcript: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let notice {
                            Text(notice)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.oraInkMuted)
                                .padding(10)
                                .oraCard()
                        }
                        ForEach(segments) { segment in
                            if editing == segment.id, onCorrect != nil {
                                CorrectionEditor(text: $draft) {
                                    onCorrect?(segment, draft)
                                    editing = nil
                                } cancel: {
                                    editing = nil
                                }
                            } else {
                                SegmentRow(segment: segment,
                                           isActive: segment.id == activeID
                                               || segment.id == currentMatch,
                                           highlight: isFinding.wrappedValue
                                               ? find.wrappedValue : "",
                                           onPlay: playback.map { player in
                                               { player.play(from: segment.start) }
                                           })
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        guard onCorrect != nil else { return }
                                        draft = segment.text
                                        editing = segment.id
                                    }
                                    .help(onCorrect == nil ? ""
                                          : "Düzeltmek için çift tıklayın")
                                    .contextMenu {
                                        if onCorrect != nil {
                                            Button("Düzelt") {
                                                draft = segment.text
                                                editing = segment.id
                                            }
                                        }
                                        if let onRelabel {
                                            let other = segment.speaker == Channel.mic.speaker
                                                ? Channel.system.speaker : Channel.mic.speaker
                                            Button("Konuşmacıyı “\(other)” yap") {
                                                onRelabel(segment, other)
                                            }
                                        }
                                        if let onDelete {
                                            Divider()
                                            Button("Satırı sil", role: .destructive) {
                                                onDelete(segment)
                                            }
                                        }
                                    }
                            }
                        }
                        ForEach(volatileLines, id: \.0) { channel, text in
                            VolatileRow(speaker: channel.speaker, text: text)
                        }
                        Color.clear.frame(height: 1).id("son")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: OraStyle.readableWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: segments.count) { _, _ in
                    // Canlı akışta en alta yapış; konuya atlarken bunu ezme.
                    guard jumpTarget.wrappedValue == nil else { return }
                    withAnimation(OraStyle.transition) { proxy.scrollTo("son", anchor: .bottom) }
                }
                .onChange(of: jumpTarget.wrappedValue) { _, target in
                    guard let target, let id = segmentID(at: target) else { return }
                    withAnimation(OraStyle.transition) { proxy.scrollTo(id, anchor: .top) }
                    jumpTarget.wrappedValue = nil
                }
                .onAppear {
                    guard let target = jumpTarget.wrappedValue,
                          let id = segmentID(at: target) else { return }
                    proxy.scrollTo(id, anchor: .top)
                    jumpTarget.wrappedValue = nil
                }
                // Ses çalarken okunan satır görünür kalır. Yalnızca çalarken:
                // kullanıcı duraklatıp gezinirken kaydırmayı ele geçirmek yanlış.
                .onChange(of: activeID) { _, id in
                    guard let id, playback?.isPlaying == true else { return }
                    withAnimation(OraStyle.transition) { proxy.scrollTo(id, anchor: .center) }
                }
                // Yeni arama ilk eşleşmeye gider; gezinme odaklı eşleşmeyi taşır.
                .onChange(of: find.wrappedValue) { _, _ in
                    matchIndex = 0
                    if let id = currentMatch {
                        withAnimation(OraStyle.transition) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onChange(of: matchIndex) { _, _ in
                    guard let id = currentMatch else { return }
                    withAnimation(OraStyle.transition) { proxy.scrollTo(id, anchor: .center) }
                }
            }
    }

    // MARK: - Toplantı içi arama

    /// Eşleşen segmentler. Karşılaştırma yerelleştirilmiş: büyük/küçük harf ve
    /// diakritik farkı gözetmez ("bütçe" ~ "butce" değil ama "Bütçe" ~ "bütçe").
    private var matches: [Segment.ID] {
        let term = find.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinding.wrappedValue, !term.isEmpty else { return [] }
        return segments.filter { $0.text.localizedStandardContains(term) }.map(\.id)
    }

    private var currentMatch: Segment.ID? {
        guard !matches.isEmpty else { return nil }
        return matches[min(matchIndex, matches.count - 1)]
    }

    /// Sonraki/önceki eşleşme; uçlarda başa döner.
    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
    }

    private func closeFind() {
        isFinding.wrappedValue = false
        find.wrappedValue = ""
        matchIndex = 0
        findFocused = false
    }

    /// O an çalınan satır — oynatıcı yoksa hiçbiri.
    private var activeID: Segment.ID? {
        playback?.activeSegmentID(in: segments)
    }

    /// Verilen anı içeren ya da ondan sonraki ilk segment.
    private func segmentID(at time: TimeInterval) -> Segment.ID? {
        (segments.first { $0.end >= time } ?? segments.last)?.id
    }

    private var volatileLines: [(Channel, String)] {
        Channel.allCases.compactMap { channel in
            guard let text = volatileText[channel.rawValue], !text.isEmpty else { return nil }
            return (channel, text)
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment
    /// Ses bu satırı çalıyor ya da odaklı arama eşleşmesi burada.
    var isActive = false
    /// Toplantı içi aramanın terimi — metinde kalın ve Carmine görünür.
    var highlight: String = ""
    /// Ses varsa saat etiketi "buradan çal" düğmesine dönüşür.
    var onPlay: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Konuşmacı ayrımı ağırlıkla kurulur, renkle değil: mavi bir
                // etiket transkriptte gereksiz bir vurgu kaynağı oluyordu.
                Text(segment.speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(segment.channel == .mic ? Color.oraInk : Color.oraInkMuted)
                if let onPlay {
                    Button(action: onPlay) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                                .opacity(isHovered || isActive ? 1 : 0)
                            Text(segment.timeLabel)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundStyle(isActive ? Color.oraCarmine : Color.oraInkMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Kaydı buradan çal")
                    .accessibilityLabel("\(segment.timeLabel) — kaydı buradan çal")
                } else {
                    Text(segment.timeLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.oraInkMuted)
                }
            }
            Text(attributedText)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(OraStyle.bodyLineSpacing)
                .foregroundStyle(Color.oraInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Çalınan satır krem şeritle işaretlenir — kenar çubuğu seçimiyle aynı
        // dil (BRAND: vurgu için renk yıkaması yok).
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(isActive ? Color.oraChrome : Color.clear)
        }
        .padding(.horizontal, -8)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    /// Arama terimi geçen yerler kalın ve Carmine; arama yoksa düz metin.
    private var attributedText: AttributedString {
        let term = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = AttributedString(segment.text)
        guard !term.isEmpty else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: term, options: [.caseInsensitive]) {
            text[range].font = .system(.body, design: .monospaced).weight(.semibold)
            text[range].foregroundColor = Color.oraCarmine
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return text
    }
}

/// Kesinleşmemiş metin. VoiceOver bunu okumaz — sürekli değişir (DESIGN.md §6).
private struct VolatileRow: View {
    let speaker: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.oraInkMuted)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(OraStyle.bodyLineSpacing)
                .foregroundStyle(Color.oraInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }
}


/// Transkript satırını yerinde düzeltme. Kaydedilen düzeltme `corrections`
/// tablosuna da yazılır ve Faz 6'da özel sözlüğü besleyecektir.
private struct CorrectionEditor: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Düzeltilmiş metin", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.oraInk)
                .padding(8)
                .oraCard()
                .onSubmit(save)
            HStack(spacing: 8) {
                Spacer()
                Button("Vazgeç", role: .cancel, action: cancel)
                Button("Kaydet", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .onExitCommand(perform: cancel)
    }
}
