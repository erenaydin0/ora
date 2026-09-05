import SwiftUI

/// Tüm toplantıların aksiyonları tek ekranda.
///
/// Özet sekmesi "bu toplantıdan bana ne düştü" sorusunu yanıtlıyordu; asıl soru
/// sabah uygulama açıldığında sorulan **"bende ne var"**. Bu yüzden pano
/// toplantı seçiminden bağımsız bir kök yüzeydir (COMPETITION.md §4.2).
///
/// Gruplama kasıtlı olarak son tarihe göre değil **kişiye** göre: `deadline`
/// serbest Türkçe metindir ("önümüzdeki hafta"), güvenilir biçimde
/// sıralanamaz. Kime düştüğü belirsiz maddeler gizlenmez — diarization
/// olmadığı için bu bilgi çoğu zaman yoktur ve bunu saklamak yanıltıcı olur.
struct ActionBoardView: View {

    let recorder: RecordingController
    @State private var showsDone = false

    private var groups: [ActionGroup] {
        let visible = recorder.boardActions.filter { showsDone || !$0.isDone }
        let name = recorder.userDisplayName
        var mine: [BoardAction] = []
        var others: [BoardAction] = []
        var unassigned: [BoardAction] = []
        for action in visible {
            if action.isMine(userName: name) { mine.append(action) }
            else if action.isAssigned { others.append(action) }
            else { unassigned.append(action) }
        }
        return [
            ActionGroup(id: "Bana düşenler", actions: mine),
            ActionGroup(id: "Başkalarında", actions: others),
            ActionGroup(id: "Kime düştüğü belirsiz", actions: unassigned),
        ].filter { !$0.actions.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.oraBorder)
            if groups.isEmpty {
                EmptyState(icon: showsDone ? "checkmark.circle" : "checklist",
                           title: recorder.boardActions.isEmpty
                               ? "Henüz aksiyon yok"
                               : "Açık aksiyon kalmadı",
                           detail: recorder.boardActions.isEmpty
                               ? "Toplantı özetlerinden çıkan işler burada toplanır."
                               : "Tamamlananları görmek için üstteki anahtarı açın.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.id.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .kerning(0.5)
                                    .foregroundStyle(Color.oraInkMuted)
                                    .padding(.bottom, 2)
                                ForEach(group.actions) { action in
                                    BoardRow(action: action,
                                             toggle: { recorder.setActionDone(action.id, !action.isDone) },
                                             open: { recorder.openMeeting(action.meetingID) })
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: OraStyle.readableWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Aksiyonlar")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.oraInk)
                Text(countLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraInkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Tamamlananlar", isOn: $showsDone)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var countLabel: String {
        let open = recorder.openActionCount
        let done = recorder.boardActions.count - open
        return open == 0 && done == 0
            ? "Tüm toplantılardan"
            : "\(open) açık · \(done) tamamlandı — tüm toplantılardan"
    }
}

private struct ActionGroup: Identifiable {
    let id: String
    var actions: [BoardAction]
}

/// Pano satırı: onay kutusu, iş, gerekçe ve **hangi toplantıdan çıktığı**.
/// Kaynak satırına tıklamak o toplantıyı açar — madde tek başına anlaşılmazsa
/// çıkış yolu budur.
private struct BoardRow: View {

    let action: BoardAction
    let toggle: () -> Void
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: action.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(action.isDone ? Color.oraCarmine : Color.oraInkMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action.isDone ? "Tamamlandı" : "Tamamlanmadı")

            VStack(alignment: .leading, spacing: 3) {
                Text(MeetingStore.cleaned(action.task))
                    .font(.system(size: 13))
                    .foregroundStyle(action.isDone ? Color.oraInkMuted : Color.oraInk)
                    .strikethrough(action.isDone, color: Color.oraInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let context = action.context, !MeetingStore.isUnspecified(context) {
                    Text(MeetingStore.cleaned(context))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.oraInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: open) {
                    HStack(spacing: 6) {
                        if action.isAssigned {
                            Label(action.person, systemImage: "person")
                        }
                        Label(action.meetingTitle, systemImage: "text.alignleft")
                            .lineLimit(1)
                        Text(action.dateLabel)
                        if let deadline = action.realDeadline {
                            Label(deadline, systemImage: "calendar")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
                    .labelStyle(.titleAndIcon)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Kaynak toplantıyı aç")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .oraQuietCard(hovered: isHovered)
        .onHover { isHovered = $0 }
    }
}
