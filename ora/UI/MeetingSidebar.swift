import SwiftUI

/// Sol kenar çubuğu: arama + toplantı listesi.
/// Arama hem başlıkta hem FTS5 üzerinden transkript içinde çalışır.
struct MeetingSidebar: View {

    @Bindable var recorder: RecordingController
    @State private var renaming: Int64?
    @State private var draftTitle = ""
    @State private var confirmingDelete: MeetingListItem?
    @State private var confirmingAudioDelete: MeetingListItem?
    /// Arama kutusu kapalıyken yalnızca bir simgedir; liste kendi alanını
    /// sürekli bir alan kutusuna kaptırmaz.
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            SidebarSearch(text: $recorder.searchText, isOpen: $isSearching)
            list
        }
    }

    private var list: some View {
        List {
            // Pano listenin **üstünde** ve seçime dahil değil: bir toplantı
            // değil, toplantılar arası bir görünüm. Kendi vurgusunu çizer.
            Section {
                ActionBoardRow(count: recorder.openActionCount,
                               isSelected: recorder.showsActionBoard) {
                    recorder.showsActionBoard = true
                }
                .listRowInsets(EdgeInsets(top: 2, leading: -14, bottom: 2, trailing: -5))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        // Satır bir düğmedir, `List` seçimi değil: sistemin
                        // seçim kapsülü kaldırılamıyor ve bizim kartımızın
                        // altında ikinci bir renk olarak duruyordu.
                        Button { recorder.selection = meeting.id } label: {
                            MeetingRow(meeting: meeting,
                                       isSelected: recorder.selection == meeting.id,
                                       snippet: recorder.searchSnippets[meeting.id])
                        }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: -14, bottom: 2, trailing: -5))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("Yeniden adlandır") {
                                    draftTitle = meeting.title
                                    renaming = meeting.id
                                }
                                // Çakışan toplantılarda yanlış etkinlik
                                // bağlanmış olabilir; kullanıcı düzeltebilmeli.
                                let events = recorder.eventChoices(for: meeting)
                                if !events.isEmpty {
                                    Menu("Takvim toplantısını değiştir") {
                                        ForEach(events) { event in
                                            Button("\(event.title) · \(event.timeLabel)") {
                                                Task { await recorder.relinkEvent(meeting.id, to: event) }
                                            }
                                        }
                                        Divider()
                                        Button("Takvim bağını kaldır") {
                                            Task { await recorder.relinkEvent(meeting.id, to: nil) }
                                        }
                                    }
                                }
                                Divider()
                                // Ses en büyük dosyadır; notu tutup yalnızca onu
                                // atabilmek gerekiyor (COMPETITION.md §4.5).
                                Button("Yalnızca sesi sil") { confirmingAudioDelete = meeting }
                                Button("Sil", role: .destructive) { confirmingDelete = meeting }
                            }
                    }
                } header: {
                    // Başlık kartın **metniyle** aynı hizada durur. Sayı
                    // ölçümle bulundu: listenin kendi başlık girintisi kartın
                    // girintisinden 7 pt fazla (RESEARCH.md §26).
                    Text(group.id.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(Color.oraInkMuted)
                        .padding(.leading, -4)
                }
            }
        }
        .listStyle(.sidebar)
        // Yukarı/aşağı ok tuşları seçimi taşır — liste seçimi bırakıldığı için
        // bu davranış elle kuruluyor.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up:   move(-1)
            case .down: move(1)
            default:    break
            }
        }
        .overlay {
            if recorder.meetings.isEmpty {
                EmptyState(
                    icon: recorder.searchText.isEmpty ? "waveform" : "magnifyingglass",
                    title: recorder.searchText.isEmpty ? "Henüz toplantı yok" : "Sonuç yok",
                    detail: recorder.searchText.isEmpty
                        ? "Kaydettiğiniz toplantılar burada listelenir."
                        : "Başka bir kelime deneyin."
                )
                .padding(.horizontal, 24)
                // Boş durum yalnızca bilgi verir; altındaki pano satırı
                // tıklanabilir kalmalı.
                .allowsHitTesting(false)
            }
        }
        .task { await recorder.refresh() }
        .alert("Toplantıyı sil", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } })) {
            Button("Vazgeç", role: .cancel) { confirmingDelete = nil }
            Button("Sil", role: .destructive) {
                if let meeting = confirmingDelete {
                    Task { await recorder.delete(meeting.id) }
                }
                confirmingDelete = nil
            }
        } message: {
            Text("\"\(confirmingDelete?.title ?? "")\" ve ses kaydı kalıcı olarak silinecek. "
                 + "Bu işlem geri alınamaz.")
        }
        .alert("Ses kaydını sil", isPresented: Binding(
            get: { confirmingAudioDelete != nil },
            set: { if !$0 { confirmingAudioDelete = nil } })) {
            Button("Vazgeç", role: .cancel) { confirmingAudioDelete = nil }
            Button("Sesi sil", role: .destructive) {
                if let meeting = confirmingAudioDelete {
                    Task { await recorder.deleteAudio(meeting.id) }
                }
                confirmingAudioDelete = nil
            }
        } message: {
            Text("\"\(confirmingAudioDelete?.title ?? "")\" toplantısının ses dosyası silinecek. "
                 + "Transkript, özet ve aksiyonlar kalır; kayıt bir daha çalınamaz ve "
                 + "yeniden işlenemez.")
        }
        .sheet(item: Binding(
            get: { renaming.map { RenameTarget(id: $0) } },
            set: { if $0 == nil { renaming = nil } })) { target in
            RenameSheet(title: $draftTitle) { newTitle in
                Task { await recorder.rename(target.id, to: newTitle) }
                renaming = nil
            } cancel: {
                renaming = nil
            }
        }
    }

    /// Ok tuşuyla komşu toplantıya geç.
    private func move(_ delta: Int) {
        let list = recorder.meetings
        guard !list.isEmpty else { return }
        guard let current = list.firstIndex(where: { $0.id == recorder.selection }) else {
            recorder.selection = list.first?.id
            return
        }
        let next = min(max(current + delta, 0), list.count - 1)
        recorder.selection = list[next].id
    }

    /// Tarihe göre gruplanmış liste. Sıra korunur — sorgu zaten tarihe göre
    /// azalan geliyor, burada yalnızca ardışık aynı etiketliler toplanır.
    private var groups: [MeetingGroup] {
        var result: [MeetingGroup] = []
        for meeting in recorder.meetings {
            let label = meeting.groupLabel
            if result.last?.id == label {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append(MeetingGroup(id: label, meetings: [meeting]))
            }
        }
        return result
    }

}

/// Kenar çubuğu araması. Kapalıyken **yalnızca bir simge**: liste sürekli
/// duran bir alan kutusuna yer kaybetmez. Simgeye basınca alan 150 ms'de açılır
/// (BRAND: geçişler en fazla 150 ms) ve odak kutuya geçer; Escape kapatır ve
/// aramayı temizler.
private struct SidebarSearch: View {

    @Binding var text: String
    @Binding var isOpen: Bool

    @FocusState private var focused: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(OraStyle.transition) { isOpen.toggle() }
                if isOpen { focused = true } else { text = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Aramayı kapat" : "Toplantılarda ve transkriptlerde ara")
            .accessibilityLabel("Ara")

            if isOpen {
                TextField("Toplantılarda ve transkriptlerde ara", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInk)
                    .focused($focused)
                    .onExitCommand { close() }
                if !text.isEmpty {
                    Button {
                        text = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.oraInkMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aramayı temizle")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(isOpen ? Color.oraSurface
                      : isHovered ? Color.oraCarmine.opacity(0.08) : Color.clear)
        }
        .overlay {
            if isOpen {
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                    .stroke(Color.oraBorder, lineWidth: 1)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func close() {
        withAnimation(OraStyle.transition) { isOpen = false }
        text = ""
        focused = false
    }
}

/// Aksiyon panosuna giriş. Toplantı satırlarıyla aynı ölçüde ve aynı seçim
/// şeridiyle çizilir; ayrımı simge ve açık aksiyon sayısı kurar.
private struct ActionBoardRow: View {
    let count: Int
    let isSelected: Bool
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.oraPaper : Color.oraInkMuted)
                Text("Aksiyonlar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.oraPaper : Color.oraInk)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.oraPaper.opacity(0.8)
                                                    : Color.oraInkMuted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.oraCarmine
                          : isHovered ? Color.oraCarmine.opacity(0.08) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(count > 0 ? "Aksiyonlar, \(count) açık" : "Aksiyonlar")
    }
}

/// Toplantı kartı: **başlık üstte**, altında tarih-saat ve sağ uçta süre.
///
/// Seçili satırın rengi **tek**tir. Eskiden sistemin çizdiği seçim kapsülü ile
/// bizim çizdiğimiz krem şerit üst üste biniyor ve satır iki renkli görünüyordu;
/// artık yalnızca sistemin kapsülü kalıyor ve o da uygulamanın vurgu rengini
/// (Carmine) kullanıyor. Metin buna göre kâğıt rengine döner — pencere arkada
/// kalınca kapsül griye döndüğü için `controlActiveState` sorulur.
private struct MeetingRow: View {
    let meeting: MeetingListItem
    let isSelected: Bool
    /// Arama transkriptte eşleştiyse eşleşmenin geçtiği yer. Başlıkta eşleşen
    /// bir sonucun parçacığı olmaz; o zaman satır bugünküyle aynı kalır.
    var snippet: String?

    @State private var isHovered = false

    private var isRecording: Bool {
        meeting.status == MeetingRecord.Status.recording.rawValue
    }
    private var isProcessing: Bool {
        meeting.status == MeetingRecord.Status.processing.rawValue
    }

    /// Seçili satır her durumda Carmine — zemini sistem değil satır çiziyor.
    private var isHighlighted: Bool { isSelected }

    private var titleColor: Color { isHighlighted ? Color.oraPaper : Color.oraInk }
    private var metaColor: Color {
        if isHighlighted { return Color.oraPaper.opacity(0.85) }
        return isRecording ? Color.oraRed : Color.oraInkMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.dateLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(metaColor)
                        .lineLimit(1)
                }
            }

            if let snippet {
                Text(highlighted(snippet))
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                .fill(isSelected ? Color.oraCarmine
                      : isHovered ? Color.oraCarmine.opacity(0.08) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Sağ uçtaki bilgi: kayıt sürüyorsa durumu, değilse süresi.
    private var trailing: String? {
        if isRecording { return "Kayıt sürüyor" }
        if isProcessing { return "İşleniyor" }
        if meeting.duration > 0 { return meeting.durationLabel }
        return nil
    }

    private var accessibilityLabel: String {
        var parts = [meeting.title, meeting.dateLabel]
        if let trailing { parts.append(trailing) }
        if let snippet { parts.append(snippet.replacingOccurrences(of: MeetingStore.mark, with: "")) }
        return parts.joined(separator: ", ")
    }

    /// FTS5'in `snippet()` çıktısı: eşleşen kelimeler `MeetingStore.mark` ile
    /// sarılı gelir. İşaretli parçalar mürekkep ve kalın, gerisi soluk.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: MeetingStore.mark).enumerated() {
            guard !part.isEmpty else { continue }
            var piece = AttributedString(part)
            let isMatch = index % 2 == 1
            if isHighlighted {
                piece.foregroundColor = isMatch ? Color.oraPaper : Color.oraPaper.opacity(0.8)
            } else {
                piece.foregroundColor = isMatch ? Color.oraInk : Color.oraInkMuted
            }
            if isMatch { piece.font = .system(size: 11, weight: .semibold) }
            result += piece
        }
        return result
    }
}

/// Kenar çubuğunda bir gün/dönem başlığı ve altındaki toplantılar.
private struct MeetingGroup: Identifiable {
    let id: String
    var meetings: [MeetingListItem]
}

private struct RenameTarget: Identifiable { let id: Int64 }

private struct RenameSheet: View {
    @Binding var title: String
    let save: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toplantı adı")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)
            TextField("Toplantı adı", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(title) }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: cancel)
                Button("Kaydet") { save(title) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Color.oraPaper)
        .onExitCommand(perform: cancel)
    }
}
