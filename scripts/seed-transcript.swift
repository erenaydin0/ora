// Bir toplantı transkriptini ora'nın veritabanına **geliştirme amaçlı** yükler.
//
// Neden var: özet kalitesini gerçek bir toplantıyla denetlemek için mikrofon
// açıp 30 dakika konuşmak gerekmiyor. Girdi, dışa aktarılmış bir Teams/Zoom
// dökümünden üretilen JSON'dur (bkz. probes/bordro_toplanti.json).
//
// Bu bir uygulama özelliği **değildir** — uygulamada içe aktarma yoktur.
// Kullanım:
//   swiftc -parse-as-library scripts/seed-transcript.swift -o /tmp/seed
//   /tmp/seed probes/bordro_toplanti.json
//
// Yazdıktan sonra uygulamayı açıp toplantıyı seçin ve "Şimdi özetle" deyin;
// özet uygulamanın kendi hattından geçer.
import Foundation

struct Girdi: Decodable {
    struct Replik: Decodable {
        let speaker: String
        let start: Double
        let end: Double
        let text: String
        let channel: String
    }
    let title: String
    let date: String
    let duration: Int
    let segments: [Replik]
}

/// Uygulamanın sandbox konteyneri. Sabit yol yazılmaz; bundle kimliğinden kurulur.
func veritabaniYolu() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appending(path: "Library/Containers/com.orameetings.ora/Data/Library/"
                   + "Application Support/ora/ora.sqlite")
}

func kacis(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

@main struct Seed {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            FileHandle.standardError.write(Data("kullanım: seed <transkript.json>\n".utf8))
            exit(2)
        }
        let db = veritabaniYolu()
        guard FileManager.default.fileExists(atPath: db.path) else {
            FileHandle.standardError.write(Data("veritabanı yok: \(db.path)\n".utf8))
            exit(1)
        }
        guard let data = FileManager.default.contents(atPath: args[1]),
              let girdi = try? JSONDecoder().decode(Girdi.self, from: data) else {
            FileHandle.standardError.write(Data("JSON okunamadı: \(args[1])\n".utf8))
            exit(1)
        }

        var sql = """
            PRAGMA foreign_keys = ON;
            BEGIN;
            -- Kimlik **tarihtir**, başlık değil: uygulama toplantıyı özetledikten
            -- sonra yeniden adlandırıyor ve başlığa bakan bir silme mükerrer
            -- kayıt bırakıyor.
            DELETE FROM meetings WHERE date = \(kacis(girdi.date));
            INSERT INTO meetings(title, date, duration, status, template, created_at)
            VALUES (\(kacis(girdi.title)), \(kacis(girdi.date)), \(girdi.duration),
                    'ready', 'general', \(kacis(girdi.date)));

            """
        for r in girdi.segments {
            let speaker = r.channel == "mic" ? "Ben" : "Katılımcı"
            sql += """
                INSERT INTO transcripts(meeting_id, speaker, channel, text, \
                start_time, end_time, confidence, created_at)
                VALUES (last_insert_rowid(), \(kacis(speaker)), \(kacis(r.channel)), \
                \(kacis(r.text)), \(r.start), \(r.end), NULL, \(kacis(girdi.date)));

                """
        }
        sql += "COMMIT;\n"

        // `last_insert_rowid()` her INSERT'ten sonra değişir; transkript satırları
        // için toplantı kimliği sabitlenmeli.
        sql = sql.replacingOccurrences(
            of: "VALUES (last_insert_rowid(),",
            with: "VALUES ((SELECT id FROM meetings WHERE date = \(kacis(girdi.date))),")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path]
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            pipe.fileHandleForWriting.write(Data(sql.utf8))
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("sqlite3 çalıştırılamadı: \(error)\n".utf8))
            exit(1)
        }
        guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

        let mic = girdi.segments.filter { $0.channel == "mic" }.count
        print("yüklendi: \(girdi.title)")
        print("  \(girdi.segments.count) replik (\(mic) mikrofon · "
              + "\(girdi.segments.count - mic) sistem) · \(girdi.duration) sn")
        print("  uygulamayı açıp toplantıyı seçin, ardından \"Şimdi özetle\"")
    }
}
