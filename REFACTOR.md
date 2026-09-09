# ora (native) — Refactor Planı: `RecordingController`

> Bu doküman tek bir soruyu yanıtlar: **`RecordingController` gerçekten bir
> god object mu, öyleyse ne yapılmalı?** Kapsamı bu dosyadır; başka bir yeniden
> yapılandırma önerisi içermez.

Ölçüm tarihi: 2026-09-09 · Ölçülen commit: `3dcab1a`

---

## 1. Ölçüm

`ora/UI/RecordingController.swift` 1114 satır / 48 KB ile projenin en büyük
dosyası. Tek başına boyut yeterli bir gerekçe değil — `FoundationIntelligence.swift`
de 870 satır ve orası bir sorun değil. Fark ölçüldü:

| | RecordingController | FoundationIntelligence |
|---|---|---|
| Satır | 1114 | 870 |
| Bağımlılık | **11** | 1 (`FoundationModels`) |
| Dışa açık üye | **~80** (71 property + 49 metot) | 6 (protokol) |
| Çağıran dosya | **8 UI dosyası, ~157 çağrı yeri** | 1 (controller) |
| Ayrı sorumluluk (MARK) | **12** | 7, hepsi aynı konuda |

Bağımlılıklar ve dosya içindeki çağrı sayıları:

```
39  store            15  detector          10  settings
 9  vocabularyStore   9  notifications      6  intelligence
 5  live              5  capture            4  route
 4  calendar          1  transcription
```

`FoundationIntelligence` **derin**dir: tek konu, çok detay. `RecordingController`
**geniş**tir: çok konu, sığ bağ. God object'i yapan ikincisidir.

Bölüm başına satır dağılımı:

```
270 satır  İşlem hattı           ← ARCHITECTURE.md'deki Pipeline
189 satır  Liste + takvim eşleştirme
117 satır  Yayınlanan durum      ← 71 property
114 satır  Kayıt
 96 satır  Depolama (arşiv / sıkıştırma / temizlik)
 74 satır  Bağımlılıklar + init
 73 satır  Türetilmiş (yetki kapıları)
 60 satır  Algılama telleri
 45 satır  Canlı transkripsiyon
 21 satır  Sözlük
 19 satır  Toplantı sohbeti
 15 satır  Çökme kurtarma
```

---

## 2. Asıl bulgu: sorun boyut değil, iki yaşam süresinin tek nesnede olması

`stages` bir **sözlük**tür (`[Int64: Stage]`, toplantı başına). Hattın ürettiği
diğer her şey **tek değerli**dir ve seçili toplantıya aittir: `transcript`,
`summary`, `topics`, `actions`, `audioURL`, `retryableAudio`, `summaryNotice`,
`deferReason`, `error`.

Bu asimetrinin bedeli kodda sayılabilir durumda: **15 adet `onScreen(meetingID)`
+ 5 adet `selection == meetingID`** koruması. Hattın yazdığı her alanın önünde
elle konmuş bir kapı var.

RESEARCH.md §27 bu kapıların *eksikliğinden* doğan hata sınıfını zaten
belgeliyor: animasyonun yanlış toplantıya taşınması, B'nin ekranına A'nın
özetinin düşmesi, işlenen toplantıya dönüldüğünde animasyonun kaybolması.
Düzeltme çalıştı, ama düzeltmenin biçimi (her yazıma bir kapı) hatayı
**imkânsız kılmadı, sadece o günkü örneklerini kapattı**.

**Bu neden büyüyen bir maliyet:** MCP, geçmiş toplantı hafızası, otomasyonlar ve
daha gelişmiş AI — hepsi hattın yeni tüketicileridir. Bugünkü yapıda her yeni
üretilen artefakt yeni bir tek-değerli property **ve** yeni bir `onScreen`
kapısı demektir. Unutulan her kapı sessiz bir toplantılar-arası veri sızıntısıdır.
Maliyet doğrusal değil, çarpımsaldır.

## 3. İkinci bulgu: doküman yanlış değil, kod dokümandan saptı

ARCHITECTURE.md `Pipeline`'ı adıyla, kendi sözleşmesiyle (`AsyncStream<PipelineStage>`)
ve bağımlılık yönüyle (`UI → Pipeline → {Capture, Transcribe, Intelligence,
Calendar, Store}`) tarif ediyor. Kodda böyle bir tip yok; rolü `RecordingController`
üstlenmiş — dosyanın kendi başlık yorumu bunu açıkça söylüyor:

> ARCHITECTURE.md'deki `Pipeline` rolünü şimdilik bu tip üstleniyor.

Dolayısıyla bu iş **yeni mimari icat etmek değil, kodu kendi dokümanına geri
getirmektir.** Bu, işi hem küçültüyor hem de tartışmasız hale getiriyor.

## 4. Üçüncü bulgu: emniyet ağı yok

- Projede **test hedefi bulunmuyor.** Tek koşum aracı `probes/meeting_switch.swift`
  ve o da uygulama kaynaklarını elle derliyor.
- Enjeksiyon asimetrik: `capture`, `transcription`, `intelligence`, `database`,
  `settings` init'ten geçirilebiliyor; `detector`, `calendar`, `notifications`
  init içinde sabit yaratılıyor.

157 çağrı yerine dokunan bir taşımayı testsiz yapmak, §27'de düzeltilen hatayı
sessizce geri getirir.

---

## 5. Plan

Her adım tek başına commit edilebilir ve uygulamayı çalışır durumda bırakır.
Sıra "en çok acıyan yer önce" değil, **"sonrakileri mümkün kılan önce"** ilkesine
göredir.

### Adım 0 — Emniyet ağı (önkoşul, atlanamaz) — ✅ tamam (`a6f377d`)

- `oraTests` hedefi aç (swift-testing).
- `detector`, `calendar`, `notifications` için init parametresi ekle. Protokol
  gerekmiyor: somut tip + varsayılan değer yeter (bkz. §7 — DI çatısı yasağı).
- `probes/meeting_switch.swift`'teki senaryoyu ilk test olarak taşı.
- Üstüne en az şunlar: hat koşarken toplantı silme, özet başarısız olduğunda
  transkriptin korunması, `retryProcessing` yolu, güç/termal ertelemesi.

Refactor'ın doğruluk ölçütü bu testlerdir.

### Adım 1 — Pipeline'ı çıkar (asıl kazanç) — ✅ tamam

`ora/Pipeline/MeetingPipeline.swift`: `runFullPass`, `runIntelligence`,
`compressAudioIfNeeded` buraya taşınır (~270 satır).

Bu tip **hiçbir görünüm durumuna dokunmaz** — `onScreen` çağrısı içermez,
`selection` diye bir kavramı yoktur. Çıktısı olay akışıdır ve her olay
`meetingID` taşır:

```swift
struct PipelineEvent: Sendable {
    let meetingID: Int64
    let kind: Kind

    enum Kind: Sendable {
        case stage(Stage)
        case transcript([Segment])
        case summary(Ozet?, [TopicSegment])
        case actions([MeetingAction])
        case audio(URL)
        case notice(String)
        case failed(OraError)
    }
}
```

Veritabanına yazma hattın işi olarak **kalır** — "üretim her hâlükârda DB'ye,
arayüze yalnızca o toplantı ekrandayken" kuralı korunur (CLAUDE.md, UI Kuralları).

İşlem hattı sırası (CLAUDE.md) değişmez; yalnızca yeri değişir.

### Adım 2 — 15 kapıyı 1'e indir — ✅ tamam

Controller hattın akışını dinler ve süzmeyi **tek yerde** yapar:

```swift
private func apply(_ event: PipelineEvent) {
    if case .stage(let stage) = event.kind {
        stages[event.meetingID] = stage          // her zaman, seçimden bağımsız
    }
    guard event.meetingID == selection else { return }   // TEK kapı
    switch event.kind { ... }                            // ekrana yazım
}
```

**Adım 1 + 2 birlikte, §27'deki hata sınıfını yapısal olarak imkânsız kılar** ve
MCP / hafıza / otomasyon için gereken tüketici noktasını açar: yeni bir özellik
hattın olay akışına abone olur, controller'a property eklemez.

> Bu iki adım bugün bile kendini amorti eder. Adım 3-6 ertelenebilir.

### Adım 3 — `RecordingSession` — ✅ tamam

`start`, `stop`, `startLive`, `stopLive`, `apply(LiveUpdate)`, `startLevelUpdates`
+ `LiveRoute` + `activeMeetingID` / `activeEvent` (~160 satır).

Kayıt oturumunun kendi durumu vardır ve controller'ın geri kalanıyla yalnızca
"bitti, şu dosya, şu süre" üzerinden konuşur — temiz kesik.

### Adım 4 — `MeetingSuggestions`

`wireDetection` + `observeSignals` + bildirim geri çağrıları (~60 satır).

Burada bedava bir düzeltme var: `observeSignals` şu an **1 saniyelik bir `while`
döngüsüyle** `detector.pendingSignal`'i yokluyor. `detector` zaten `@Observable`;
`withObservationTracking` ile olay tabanlı hale gelir. CLAUDE.md'nin "polling
yok" ilkesiyle de bu daha tutarlıdır.

### Adım 5 — `MeetingLibrary`

`refresh`, `load`, `delete`, `rename`, `correct`, `deleteSegment`, `setSpeaker`,
`searchText`, `selection`, `searchSnippets`, `boardActions` (~190 satır).

Controller'ın en "view model"vari kısmı; en sona bırakılabilir çünkü zararsızdır.

### Adım 6 — Takvim eşleştirmesini Calendar'a geri ver

`matchCalendar`'daki puanlama ve `decisiveMargin` kararı `CalendarReader`'a
(ya da `CalendarMatcher`'a) taşınır. Controller'da yalnızca "kullanıcıya
sorulacak adaylar" durumu (`eventChoices`, `choiceMeetingID`) kalır.

Şu an eşleştirme **politikası** UI katmanında duruyor; ARCHITECTURE.md'nin
bağımlılık yönü buna izin vermiyor.

### Adım 7 — Dokümanlar

CLAUDE.md'nin "Bu Dosyayı Güncel Tutma Kuralı" gereği **aynı commit'lerde**:

- ARCHITECTURE.md'deki `PipelineStage` sözleşmesi gerçek koda göre güncellenir.
  Bugün doküman ile kod ayrışmış durumda: `deferred` / `failed` kodda `Stage`
  içinde yok, `stages` sözlüğü ve `SummaryContext` dokümanda yok.
- CLAUDE.md'nin "Proje Düzeni" bölümüne `ora/Pipeline/` girer, `ora/UI/`
  listesinden taşınanlar çıkar.

---

## 6. Yapılmaması gerekenler

- **DI çatısı ekleme.** Gerekçesi §7'de.
- **Hepsini tek commit'te yapma.** 157 çağrı yeri var; tek seferde kırılırsa
  nerede kırıldığı bulunamaz.
- **20 küçük dosyaya bölme.** Hedef 6 anlamlı modül, mikro-sınıf koleksiyonu değil.
- **Adım 0'ı atlama.**
- **İşlem hattı sırasını değiştirme.** Taşınan şey kod, sıra değil.
- **`variation` / ilk geçiş örnekleme ayrımına dokunma.** RESEARCH.md §23-24
  ölçümleri varsayılan örneklemeyle alındı.

---

## 7. Neden DI çatısı yok — gerekçenin kaydı

ARCHITECTURE.md "Bilinçli olarak yapılmayanlar" başlığı altında **"Bağımlılık
enjeksiyonu çatısı yok — init üzerinden geçir"** diyor ama komşu iki maddenin
aksine gerekçesini yazmıyor. Gerekçe bu bölümde kayda geçiriliyor.

Önce bir ayrım: yasak olan **çatı/konteyner**dır, enjeksiyon değil. Proje baştan
sona kurucu enjeksiyonu (constructor injection) kullanıyor —
`RecordingController(capture:transcription:intelligence:database:settings:)`
bunun kendisi.

1. **Tek bağımlılık kuralının özel hâli.** CLAUDE.md: *"Tek harici bağımlılık
   GRDB.swift'tir. Başka SPM paketi eklemeden önce sor."* Swinject, Factory,
   Resolver, Needle — hepsi ikinci bir SPM paketidir. En güçlü gerekçe budur ve
   tek başına yeter.

2. **Nesne grafiği tek ve statik.** Uygulamada tek bir kompozisyon kökü var:
   `oraApp` bir `RecordingController` yaratıyor, o da 11 bağımlılığını kuruyor.
   Konteynerler, çok sayıda yerde, farklı yaşam sürelerinde, koşullu olarak
   kurulan grafikler için kazanç sağlar. Burada öyle bir grafik yok.

3. **Derleme zamanı güvenliğini kaybettirir.** Konteyner tabanlı DI,
   "X'i kaydetmeyi unutmuşsun"u derleme hatasından **çalışma zamanı çökmesine**
   çevirir. CLAUDE.md'nin "Asla sessizce çökme" kuralıyla doğrudan çelişir.

4. **Swift'in kendi mekanizması zaten yeterli.** Varsayılan değerli init
   parametresi test edilebilirliği sağlıyor ve bu kanıtlanmış durumda:
   `probes/meeting_switch.swift` gerçek `RecordingController` ve gerçek
   `MeetingStore` ile koşarken yalnızca `Intelligent`'ı sahteliyor — hiçbir çatı
   kullanmadan.

5. **Swift 6 eşzamanlılığıyla kötü geçiniyor.** Çoğu konteyner `Any` tip silme +
   çalışma zamanı arama üzerine kurulu; `Sendable` ve aktör izolasyonu
   denetimleri bu yolda ya kayboluyor ya da `@unchecked` ile bastırılıyor.

**Bu planla ilişkisi:** Adım 0 (`detector` / `calendar` / `notifications` için
init parametresi) kuralın ihlali değil, kuralın **reçetesidir**. Enjeksiyon
noktası ekliyoruz, konteyner değil.

---

## 8. Karar

Adım 0-1-2 birlikte, bugün üretimdeki bir hata sınıfını yapısal olarak kapatır
ve gelecekteki hat tüketicilerinin (MCP, geçmiş toplantı hafızası, otomasyon)
bağlanacağı yüzeyi açar. Faz 9'a bu başlıklarla giriliyorsa **bu üç adım o işin
önüne konur.**

Adım 3-6 acil değildir. Kod bugünkü haliyle çalışıyor, yorumları gerekçeleriyle
yazılmış ve §27 düzeltmesi doğru. Fırsat buldukça, tek tek, kendi commit'leriyle.

---

## 9. Adım 0-1-2 sonucu (2026-09-09)

| Ölçüt | Önce | Sonra |
|---|---|---|
| `RecordingController` satır | 1114 | 958 |
| `onScreen` çağrısı | **15** | **1** (+1 controller'ın kendi kontrolü) |
| Test | yok | 13 test, `xcodebuild test -scheme ora` |
| `Pipeline` ayrı katman | yok | `ora/Pipeline/` (363 satır) |

Emniyet ağının gerçekten yakaladığı **ölçülerek** doğrulandı: `apply(_:)`
içindeki tek kapı kaldırıldığında §27 testi kırılıyor
(`"A genel bakış: …" == "B'nin kendi özeti"` başarısız).

### Yol boyunca kapanan üç hata

Hiçbiri planın hedefi değildi; hattı ayırmak ortaya çıkardı.

1. **Takvim başlığı üretilmiş başlıkla eziliyordu.** Karar
   `activeEvent == nil`'den okunuyordu; `activeEvent` yalnızca kayıt oturumu
   boyunca doluydu, "Şimdi özetle" ve "Yeniden dene" yollarında her zaman nil.
   Bu yollarda takvimden gelen ad Foundation Models'ın ürettiği adla
   değiştiriliyordu — CLAUDE.md'nin başlık önceliği kuralının ihlali. Artık
   toplantı kaydındaki `calendar_event_id`'den okunuyor.
2. **`isTranscribing` hat koşarken false dönebiliyordu.** `stages` sözlüğünden
   türetiliyordu ve `delete(_:)` satırı sözlükten silince hat hâlâ koşarken
   yetki kapıları (düzeltme, elle özetleme, yeniden dene) açılıyordu. Artık
   hattın kendi kaydından: `pipeline.isRunning`.
3. **`runIntelligence(duration:)` parametresi hiç kullanılmıyordu** —
   `MeetingMetrics` kaldırıldığında kalmış ölü bağ. Silindi.

### Ölçüm sırasında düzeltilen doküman sapmaları

- ARCHITECTURE.md'nin `PipelineStage` sözleşmesi hiç var olmamış bir tipi
  tarif ediyordu; gerçek `PipelineStage` + `PipelineEvent` ile değiştirildi.
- ARCHITECTURE.md ve CLAUDE.md hâlâ `MeetingMetrics`'e atıf yapıyordu; tip
  kodda yok.

---

## 10. Adım 3 sonucu (2026-09-09)

| Ölçüt | Adım 2 sonrası | Adım 3 sonrası |
|---|---|---|
| `RecordingController` satır | 958 | **861** |
| `ora/Pipeline/` satır | 363 | 542 |
| Test | 13 | **18** |

`ora/Pipeline/RecordingSession` kayıt **sürerkenini** yürütüyor: ses yazımı
(birincil) + canlı transkripsiyon (en iyi çaba). `MeetingPipeline`'ın simetriği
— o kayıt bittikten sonrasını yürütür. Sırayı ikisi de değil controller kurar.

`ora/Capture/` altında **değil**: Capture ile Transcribe'ı birlikte kullanıyor
ve ARCHITECTURE.md'nin bağımlılık yönü alt modüllerin birbirini çağırmasını
yasaklıyor.

**Yeni protokol: `LiveTranscribing`.** `AudioCapturing` / `Transcribing` /
`Intelligent` ile aynı gerekçe (ARCHITECTURE.md, Test edilebilirlik). Bu olmadan
oturum testi gerçek `SpeechAnalyzer` kuruyor ve ölçüm makinenin Speech durumuna
bağımlı kalıyordu — oysa **kural #2** (canlı transkripsiyon asla kaydın önüne
geçmez) tam olarak burada ölçülmeli. Artık ölçülüyor: canlı transkripsiyon
duraklatıldığında not düşüyor, kayıt sürüyor ve ses dosyası üretiliyor.

Ölçülerek doğrulandı: `meetingID`, `capture.start` **başarılı olduktan sonra**
kurulmalı. Eski sıra (önce kur, hatada geri al) geri konulduğunda
`basarisizBaslangicOturumAcmaz` kırılıyor.

### Adım 3'te çıkan bulgu: `channelLevels` ölü

Hiçbir arayüz `channelLevels`'ı okumuyor. Menü bar native `NSMenu`'ye
geçtiğinde (`.menuBarExtraStyle(.menu)`) seviye göstergesi düşmüş, besleyen
zamanlayıcı kalmış: kayıt boyunca 100 ms'de bir MainActor'da boşa yazılıyor —
60 dakikalık bir toplantıda 36.000 gereksiz uyanma. CLAUDE.md hâlâ "kayıt
sırasında kırmızı nokta ve kanal seviyeleri" diyor; nokta var, seviyeler yok.

**Silinmedi, işaretlendi.** İki yol var ve ikisi de kullanıcının kararı:
göstergeyi geri getirmek (native menü çizemez — popover gerekir, DESIGN.md §2
ile çakışır) ya da `channelLevels` + `levelTask` + `AudioCapturing.levels`
zincirini birlikte silmek. İkincisi Capture katmanına dokunur, Adım 3'ün
kapsamı değil.

### Kapsam dışı bırakılanlar

- **Kullanıcının elle değiştirdiği başlık.** "Şimdi özetle" hâlâ üretilmiş
  başlığı yazabilir; "yeniden adlandırıldı" diye bir işaret yok. Ayrı iş.
- **`Pipeline`'ı `actor` yapmak.** Ağır iş zaten `Transcribing` ve
  `Intelligent` içindeki asenkron API'lerde geçiyor; `@MainActor` kalması
  davranışı birebir koruyor. Ayrı adım.
- **Kalan 5 `selection == meetingID`.** Hepsi liste/CRUD tarafında
  (`load`, `delete`, `relinkEvent`) — Adım 5'in konusu.
- `startLive()`'daki iki gereksiz `await` uyarısı: refactor'dan önce de
  vardı, dokunulmadı.
