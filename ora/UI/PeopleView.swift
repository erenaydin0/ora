import SwiftUI

/// Kişi sayfası (COMPETITION.md §4.11): bir kişiyle yapılan toplantılar,
/// ona düşen açık aksiyonlar ve son toplantının kararları.
///
/// **LLM yok** — hepsi var olan tablolardan okunur. Pano gibi toplantılar
/// arası bir kök yüzeydir; satıra tıklamak kaynak toplantıyı açar.
struct PeopleView: View {

    let recorder: RecordingController
    @State private var selected: String?
    @State private var detail: MeetingStore.PersonDetail?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 220)
            Divider().overlay(Color.oraBorder)
            Group {
                if let detail {
                    PersonPage(detail: detail, recorder: recorder)
                } else {
                    EmptyState(icon: "person.2", title: "Bir kişi seçin",
                               detail: "Birlikte yaptığınız toplantılar, ona düşen işler "
                                   + "ve son kararlar burada görünür.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oraPaper)
        .task(id: selected) { await load() }
        .onAppear {
            if selected == nil { selected = recorder.people.first?.name }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("KİŞİLER")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.oraInkMuted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ForEach(recorder.people) { person in
                    PersonRow(person: person, isSelected: person.name == selected) {
                        selected = person.name
                    }
                }
            }
            .padding(10)
        }
        .background(Color.oraPaper)
    }

    private func load() async {
        guard let selected else { detail = nil; return }
        let loaded = await recorder.personDetail(selected)
        // Yavaş gelen yanıt yeni seçimin üstüne yazılmasın.
        if self.selected == selected { detail = loaded }
    }
}

private struct PersonRow: View {
    let person: MeetingStore.Person
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Initials(name: person.name, size: 22, inverted: isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.oraPaper : Color.oraInk)
                        .lineLimit(1)
                    Text("\(person.meetingCount) toplantı")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.oraPaper.opacity(0.85)
                                                    : Color.oraInkMuted)
                }
                Spacer(minLength: 0)
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
        .accessibilityLabel("\(person.name), \(person.meetingCount) toplantı")
    }
}

private struct PersonPage: View {
    let detail: MeetingStore.PersonDetail
    let recorder: RecordingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Initials(name: detail.name, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.oraInk)
                            .textSelection(.enabled)
                        Text(summaryLine)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.oraInkMuted)
                    }
                }

                if !detail.openActions.isEmpty {
                    section("Açık aksiyonlar") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(detail.openActions) { action in
                                BoardRow(action: action,
                                         toggle: { recorder.setActionDone(action.id, true) },
                                         open: { recorder.openMeeting(action.meetingID) },
                                         remind: recorder.remindersEnabled ? {
                                             Task { await recorder.addToReminders(actionID: action.id) }
                                         } : nil)
                            }
                        }
                    }
                }

                if let decisions = detail.lastDecisions {
                    section("Son kararlar") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                recorder.openMeeting(decisions.meeting.id)
                            } label: {
                                Text("\(decisions.meeting.title) · "
                                     + decisions.meeting.date.formatted(date: .abbreviated,
                                                                        time: .omitted))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.oraInkMuted)
                            }
                            .buttonStyle(.plain)
                            .help("Toplantıyı aç")
                            ForEach(Array(decisions.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(Color.oraInkMuted)
                                    Text(item)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.oraInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                section("Toplantılar") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(detail.meetings) { meeting in
                            MeetingLink(meeting: meeting) { recorder.openMeeting(meeting.id) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: OraStyle.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryLine: String {
        var parts = ["\(detail.meetings.count) toplantı"]
        if let last = detail.meetings.first {
            parts.append("son: " + last.date.formatted(date: .abbreviated, time: .omitted))
        }
        if !detail.openActions.isEmpty { parts.append("\(detail.openActions.count) açık aksiyon") }
        if detail.doneCount > 0 { parts.append("\(detail.doneCount) tamamlandı") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased(with: Locale(identifier: "tr_TR")))
                .font(.system(size: 13, weight: .medium))
                .kerning(0.8)
                .foregroundStyle(Color.oraInk)
            content()
        }
    }
}

private struct MeetingLink: View {
    let meeting: MeetingStore.PersonDetail.MeetingRef
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack {
                Text(meeting.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.oraInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.oraInkMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: OraStyle.cornerRadius, style: .continuous)
                    .fill(isHovered ? Color.oraCarmine.opacity(0.08) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Toplantıyı aç")
    }
}

/// Baş harfler — renkli avatar yok; krem daire üzerinde mürekkep.
private struct Initials: View {
    let name: String
    var size: CGFloat = 20
    var inverted = false

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(inverted ? Color.oraCarmine : Color.oraInk)
            .frame(width: size, height: size)
            .background(Circle().fill(inverted ? Color.oraPaper : Color.oraChrome))
    }

    /// Türkçe locale şart: "ırmak" → "I" değil.
    static func initials(_ name: String) -> String {
        let turkish = Locale(identifier: "tr_TR")
        let letters = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased(with: turkish) } }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
