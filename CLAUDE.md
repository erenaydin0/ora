# ora (native) — Claude Code Project Memory

## Project Overview
ora, toplantıları kaydeden, transkribe eden ve özetleyen bir macOS uygulamasıdır.
Tüm işlem cihaz üstünde yapılır; hiçbir veri cihazı terk etmez.

- Uygulama adı: her zaman küçük harf **"ora"** — asla "Ora" veya "ORA"
- Birincil kullanıcı: Teams/Slack kullanan Türkçe konuşan profesyoneller
- Birincil toplantı dili: **Türkçe** (İngilizce de tam desteklenir)
- Platform: **yalnızca macOS 26+ / Apple Silicon**. Windows kapsam dışıdır —
  gelecekte de planlanmıyor, bu yüzden hiçbir yerde soyutlama katmanı yazma.

Bu proje, Electron + Python + WhisperX ile yazılmış önceki ora'nın
(`../`) yerine geçer. Neden değiştirildiğini ve hangi ölçümlere dayandığını
**RESEARCH.md** anlatır — o dosya tartışmayı kapatan ölçümleri içerir,
oturum başında oku ve varsayımları yeniden tartışma.

## Tech Stack — hepsi Apple yerel, sıfır çalışma zamanı bağımlılığı
| Katman | Teknoloji | Not |
|---|---|---|
| UI | SwiftUI + AppKit köprüsü | Web view yok, React yok |
| Ses yakalama (sistem) | CoreAudio süreç tap'i (`CATapDescription`) | Ekran kaydı izni **istemez**; süreç/bundle bazlı seçim yapar |
| Ses yakalama (mikrofon) | AVAudioEngine | |
| Transkripsiyon | `Speech.DictationTranscriber` + `SpeechAnalyzer` | tr_TR destekli, cihaz üstü |
| Özetleme / sohbet | `FoundationModels` (Apple yerel ~3B LLM) | tr-Latn-TR destekli, indirme yok |
| Veritabanı | SQLite + FTS5, **GRDB.swift** üzerinden | SwiftData'da tam metin arama yok; tek SPM bağımlılığı |
| PDF dışa aktarım | `ImageRenderer` / PDFKit | WeasyPrint yok |
| İkonlar | SF Symbols | Lucide yok |

**Tek harici bağımlılık GRDB.swift'tir.** Başka SPM paketi eklemeden önce sor.
Python yok, Node yok, Electron yok, model dosyası indirme yok.

## Kritik Mimari Kurallar — ASLA İHLAL ETME
1. Kayıt sırasında **LLM çağrısı yok** (Foundation Models yalnızca kayıt bittikten sonra).
   Canlı transkripsiyon ise **serbesttir ve tercih edilir** — ölçüldü: gerçek zamanlı
   akışta tek çekirdeğin %1'i, 7.7 MB tepe bellek (bkz. RESEARCH.md §6).
   Eski ora'daki "kayıt sırasında transkripsiyon yok" kuralı WhisperX+PyTorch
   ağırlığından doğmuştu; o kısıt artık geçerli değil.
2. Canlı transkripsiyon **asla kaydın önüne geçmez**: ses yazımı birincil iştir,
   transkripsiyon en iyi çaba (best-effort) ikincil tüketicidir. Transkripsiyon
   hata verirse veya geri kalırsa kayıt kesintisiz sürer ve kayıt sonrası
   tam bir geçiş (full pass) yapılır.
3. Hiçbir veri harici API'ye veya sunucuya gönderilmez — asla
4. İşlem yalnızca kayıt bittikten sonra, kullanıcının tetikleyici ayarına göre başlar
5. Sistem sesi **CoreAudio süreç tap'i** ile yakalanır
   (`AudioHardwareCreateProcessTap` + `CATapDescription`, macOS 14.2+).
   ScreenCaptureKit **kullanılmaz** — ekran kaydı izni ister, oysa tap istemez
   (doğrulandı, bkz. RESEARCH.md §5). ScreenCaptureKit yalnızca tap'in
   çalışmadığı bir durum çıkarsa yedek yoldur.
6. Kullanıcıya görünen tüm metinler Türkçe
7. Tüm SQLite yazımları transaction içinde (GRDB `try db.write { }`)
8. BRAND.md paletinin dışında renk kullanma. Uygulama ikonu da bu paletten
   çizilir (`scripts/make-icon.swift`) ve **kenardan kenara dolu** olmalıdır —
   yuvarlatılmış köşeyi ve gölgeyi macOS 26 kendisi uygular; kendi kabuğunu
   çizen sanat eseri Dock'ta boş bir çerçeve gibi görünür (RESEARCH.md §20).
   İkon: konuşan ağız — Carmine zemin, Carmine Deep dudak, krem açıklık
   ve söz damlası. `.oraCarmine` kimlik ve AccentColor’dır; kenar çubuğu
   seçimi ve kayıt değildir. `.oraCarmineDeep` yalnızca işaret.
9. Active Red (#E53935) yalnızca kayıt butonu, menü bar noktası ve kenar
   çubuğundaki canlı kayıt noktası için
9b. Uygulamanın vurgu rengi (`AccentColor`) `.oraCarmine`’dir — sistem
    mavisi ve eski Soft Apricot kullanılmaz. Anahtarlar, sekmeler ve
    varsayılan butonlar Carmine alır. **Kenar çubuğunda seçili kart dolu
    Carmine'dir**, metni kâğıt rengidir (eski `.oraChrome` şerit bırakıldı:
    sistemin seçim kapsülü liste odağı gidince griye dönüyor ve kartın altında
    ikinci bir renk bırakıyordu — bu yüzden `List` seçimi de kullanılmaz).
    Sohbet araç çubuğu kapalıyken mürekkep, açıkken Carmine. Active Red
    Carmine’den açıkça ayırt edilebilir kalmalı.
10. Uygulama adı her zaman küçük harf "ora"
11. Kayıt **stereo** yazılır: kanal 0 = mikrofon, kanal 1 = sistem sesi.
    Kanallar asla tek kanala karıştırılmaz. Kısa kalan kanal sessizlikle
    doldurulur, kırpılmaz. Disk formatı **16 kHz · 16 bit · stereo WAV**
    (saatte ~230 MB). Örnekler buffer sırasına göre değil, host time'dan
    hesaplanan **mutlak frame konumuna** yazılır — hizalamayı bu sağlar.
12. Ses **artımlı olarak** diske yazılır (1 sn'de bir flush, dosya varsa append).
    Ses hiçbir zaman tamamı RAM'de tutulmaz — önceki ora'nın en pahalı hatası buydu.

## İşlem Hattı Sırası
Bu sıra asla değişmez:
1. **Kayıt sırasında** (eşzamanlı, iki iş):
   a. Ses artımlı olarak diske yazılır — birincil iş, asla ertelenmez
   b. Canlı transkripsiyon her kanal için ayrı `SpeechAnalyzer` ile koşar
      (`.volatileResults` ile ekranda akan metin, kesinleşenler DB'ye)
   LLM bu aşamada **çalışmaz**.
2. Toplantı bitti → kayıt sonrası geçiş hemen başlar (bekleme yok).
   Tek istisna: sistem Low Power Mode açıksa veya termal durum `.serious`+ ise
   kullanıcıya sor. Ayrı bir "şarjı bekle" alt sistemi **yoktur**.
3. Kayıt sonrası tam transkripsiyon geçişi — canlı geçişte kaçan/geri kalan
   bölümleri kapatır ve güncel vocabulary'yi uygular. Canlı sonuç zaten
   tamsa bu adım hızla biter.
4. Foundation Models ile **noktalama restorasyonu** (zorunlu adım)
5. Foundation Models ile map-reduce özetleme → konu blokları (başlık +
   maddeler) ve aksiyonlar parça aşamasında; genel bakış ve kararlar
   birleştirme aşamasında
6. Son kontrol: üretilen cümlelerin dilbilgisi düzeltilir (olgu koruma
   güvenceli; sayı ve özel isim değişirse satır reddedilir — §24.3)
7. SQLite güncelle (summaries + action_items + topic_segments)
8. Kullanıcıya bildir

## Ses Yakalama Kuralları — ölçülmüş davranış
- Sistem sesi: `CATapDescription` + `AudioHardwareCreateProcessTap`.
  Doğrulandı: `OSStatus 0`, 48 kHz stereo float32, **ekran kaydı izni istenmedi**.
- Tercih edilen kurulum — toplantı uygulamasını **adıyla** yakala. Hedef
  listesi `MeetingApps.tapTargets(preferring:)`'ten gelir ve uygulamanın
  **yardımcı süreçlerini de** içerir: ölçüldü (RESEARCH.md §28.3) — Teams'te
  sesi `com.microsoft.teams2` değil `...helper` / `...modulehost` üretiyor;
  ana bundle ID'yi hedefleyen tap tek frame bile vermiyor. Liste
  `NSWorkspace`'ten değil **CoreAudio süreç listesinden** toplanır.
  ```swift
  let desc = CATapDescription()
  desc.bundleIDs = MeetingApps.tapTargets(preferring: "com.microsoft.teams2")
  // → ["com.microsoft.teams2", "com.microsoft.teams2.helper",
  //    "com.microsoft.teams2.modulehost", "com.microsoft.teams2.notificationcenter"]
  desc.isExclusive = false          // yalnızca bunları yakala
  desc.isMono     = true            // mono mixdown — WAV'ın ch1'i tek kanal
  desc.isMixdown  = true
  desc.isPrivate  = true            // tap yalnızca bize görünür
  desc.muteBehavior = .unmuted      // kullanıcı sesi duymaya devam eder
  desc.isProcessRestoreEnabled = true  // uygulama yeniden başlarsa tap'e geri döner
  ```
  Bu, Spotify'ı, bildirimleri ve diğer uygulamaların sesini transkripte
  **sokmaz** — global yakalamaya göre gerçek bir kalite kazancıdır.
- **Tarayıcılar tap hedefi OLARAK KULLANILMAZ.** Ölçüldü (RESEARCH.md §13.3):
  tarayıcı sesi ana uygulamadan değil yardımcı süreçten çıkıyor
  (Safari → `com.apple.WebKit.GPU`). `com.apple.Safari`'yi hedefleyen bir tap
  **sessizlik** yakalar. Tarayıcı toplantıları doğrudan global tap'e gider.
  Yardımcı süreci hedeflemek teknik olarak **çalışıyor** (§28.3) ama tarayıcı
  yardımcısı tüm sekmelere hizmet ettiği için "yalnızca toplantı" garantisi
  vermez; kural bu yüzden değişmedi.
- Toplantı uygulaması tespit edilemiyorsa global tap'e düş:
  `desc.processes = [kendi süreç nesnemiz]; desc.isExclusive = true`
  (kendimizi hariç tut — geri besleme döngüsünü önler).
- **Kapsamlı tap gözcüsü zorunlu.** Kapsamlı tap 3 saniye boyunca hiç frame
  vermezken sistemde (bizim dışımızda) ses çalan bir süreç varsa, hedeflediğimiz
  bundle ID sesi üretmiyordur (Electron yardımcı süreçleri) → global tap'e geçilir.
  Sessizce boş bir sistem kanalı kaydetmek kabul edilemez bir hata modudur.
- Tap **doğrudan okunmaz**: özel bir toplama (aggregate) cihazına
  `kAudioAggregateDeviceTapListKey` ile bağlanır, saat kaynağı olarak varsayılan
  çıkış cihazı verilir, `AudioDeviceCreateIOProcIDWithBlock` ile okunur.
- `muteBehavior` asla `.muted` yapılmaz; kullanıcı toplantıyı duymaya devam etmeli.
- Tap bir toplama (aggregate) cihazına bağlanır, ondan `AVAudioEngine`/IOProc ile
  okunur. Mikrofon ayrı yakalanır; ikisi **host time** damgasıyla hizalanır.

## Speech API Kuralları — ölçülmüş davranış
- **`SpeechTranscriber` DEĞİL, `DictationTranscriber` kullan.** `SpeechTranscriber`
  yalnızca 30 locale destekler ve **Türkçe içermez**. `DictationTranscriber`
  43 locale destekler, `tr_TR` dahildir. Bu ayrım projenin can damarıdır.
- Yapılandırma:
  ```swift
  DictationTranscriber(
    locale: Locale(identifier: "tr-TR"),
    contentHints: [.farField],                  // toplantı sesi uzak alan
    transcriptionOptions: [.punctuation],
    reportingOptions: [.frequentFinalization],
    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
  )
  ```
- **`.punctuation` Türkçe'de etkisiz** — çıktı noktalamasız gelir (ölçüldü).
  Noktalamayı hat adımı 4'te Foundation Models ile geri koy. Bu adımı atlama;
  noktalamasız transkript hem okunmaz hem de özetleme kalitesini düşürür.
- Kelime düzeyi zaman damgası `AttributedString` run'larının `.audioTimeRange`
  niteliğinden okunur — `attributeOptions` içinde `.audioTimeRange` olmalı.
- Özel sözlük (vocabulary) `ContentHint.customizedLanguage(modelConfiguration:)`
  + `SFSpeechLanguageModel.Configuration` ile verilir. Vocabulary özelliğinin
  arka ucu budur; ayrı bir düzeltme katmanı yazma.
- **Sözlük sabitleri ölçümle seçildi (RESEARCH.md §17.1): `count = 30`,
  `weight = 1.0`.** Terim tutma 2/5'ten 4/5'e çıkıyor. `count`'u yükseltmek
  (200) sonucu **kötüleştiriyor**. Bu iki sayıyı değiştirmeden önce
  `probes/vocabulary.swift`'i yeniden koştur.
- Dil seçimi: `DictationTranscriber.installedLocales` ile kurulu mu bak,
  değilse `AssetInventory` üzerinden indir. `maximumReservedLocales` = 5.
- **`AnalyzerInput` damgası tam frame sayısından kurulur.** Ölçüldü
  (RESEARCH.md §14.1): `CMTime(seconds:preferredTimescale:)` yuvarlaması
  ardışık buffer'ları çakıştırıyor ve motor `SFSpeechErrorDomain 2` veriyor —
  saniye cinsinden monotonluk kelepçesi bunu **çözmüyor**.
  - Kayıt sonrası tam geçişte damga **verilmez** (dosya akışı kesintisiz).
  - Canlı modda `CMTime(value: frameCount, timescale: Int32(analysisFormat.sampleRate))`
    kullanılır ve monoton kelepçelenir; buffer düşerse ileri sıçranır.
- Konuşulan dili tanıyan bir Apple API'si **yok**. "Otomatik dil", sesin ilk
  ~40 saniyesini kurulu adaylarla ayrı ayrı çözüp ortalama güven skorunu
  karşılaştırarak seçer. Aday havuzu yalnızca **kurulu** dillerdir; seçim için
  dil paketi indirilmez.

## Foundation Models Kuralları — ölçülmüş davranış
- Kullanmadan önce **her zaman** `SystemLanguageModel.default.availability`
  kontrol et. `.unavailable(.appleIntelligenceNotEnabled)` gerçek ve sık bir
  durumdur — kullanıcıyı Türkçe bir onboarding ekranıyla Ayarlar'a yönlendir,
  sessizce başarısız olma.
- **Bağlam penceresi 4096 token.** Ölçüm: ~15.600 Türkçe karakter (≈3.800 token)
  geçti, ~31.200 karakter `exceededContextWindowSize` verdi. Türkçe'de kabaca
  **4 karakter ≈ 1 token**.
- Bu yüzden **map-reduce zorunludur**: transkripti **6.000 karakterlik**
  parçalara böl, her parçayı ayrı özetle, sonra kısmi özetleri birleştirip nihai
  özeti üret. "4 karakter ≈ 1 token" oranı **iyimserdi**: gerçek bir toplantı
  transkriptinde ölçülen oran **2,45 karakter/token** (RESEARCH.md §23) ve
  10.000 karakterlik parça 4.089 token ederek pencereyi taşırıyordu. Transkripti asla kırpma —
  önceki ora'da `MAX_TRANSCRIPT_CHARS = 14_000` yüzünden 60 dakikalık
  toplantının %75'i sessizce çöpe gidiyordu. **Bu hatayı tekrarlama.**
- **Parça çıktısı `ParcaOzeti`'dir: konu blokları (başlık + maddeler) **ve**
  o parçada üstlenilen aksiyonlar.** Konu yalnızca başlık değildir — gövdesi
  notun kendisidir. Birleştirme adımı yalnızca genel bakış ve kararları üretir;
  **aksiyon üretmez**, çünkü konu notlarında konuşmacı bilgisi yoktur.
- **Katılımcı listesi isteme yazılmaz.** A/B ölçüldü (RESEARCH.md §23): kapalı
  isim listesi verildiğinde model onu kısıt değil *menü* gibi kullanıyor,
  görevler belirsizleşiyor ve son tarihlere toplantı tarihi sızıyor. Liste
  yalnızca **doğrulamada** kullanılır.
- **Konuşmacı etiketi üç biçimde sızıyor** (§24.4): `Ben: …`, `Katılımcı, …`
  ve ayraçsız `Ben …`. Üçü de `withoutSpeakerPrefix` ile kesilir; isteme ayrıca
  üçüncü şahıs kuralı yazılmıştır.
- **Model, içeriği olmayan alanı istemdeki en yakın metinle doldurur.** "Şunu
  yazma" demek 3B modelde işe yaramıyor, tetikliyor. İki sızıntı kodda kesilir
  (`FoundationIntelligence.validated`): bağlam konu başlığını tekrarlıyorsa
  düşürülür, son tarih toplantı tarihinin kendisiyse "belirtilmedi" olur.
- Yapılandırılmış çıktı için **`@Generable` + `@Guide` kullan**, elle JSON
  ayrıştırma yazma. Ölçüldü: aksiyon maddelerini `kisi`/`gorev`/`sonTarih`
  alanlarıyla doğru üretiyor. `sonTarih` alanını şemadan çıkarma — önceki
  ora'da istenmediği için DB'deki `deadline` hep NULL kalıyordu.
- **İstemler İngilizce yazılır, çıktı dili açıkça Türkçe istenir.** Ölçüldü
  (RESEARCH.md §24.2): İngilizce istemle madde uzunluğu 60→70 karakter,
  çıkarılan karar 3,3→5,7, aksiyon 2,7→3,7, genel bakış/karar tekrarı 1,7→0,7;
  süre aynı, guardrail ikisinde de 8/8. Model İngilizce ağırlıklı eğitilmiş.
  Kullanıcıya görünen hiçbir metin bundan etkilenmez.
- **Daha güçlü bir cihaz üstü model yok** (§24.1). `.contentTagging` daha büyük
  bir model değil, aynı modelin başka kullanım biçimi. Tek kaldıraç
  `SystemLanguageModel.Adapter` — cihazda kalan, eğitilmiş bir LoRA katmanı.
- **Kullanıcı özeti beğenmezse yeniden ürettirebilir.** Aynı istem çoğu zaman
  aynı özeti verdiği için yeniden üretimde örnekleme serbestleştirilir
  (`GenerationOptions(sampling: .random(probabilityThreshold: 0.95),
  temperature: 0.9)`). **İlk geçiş varsayılan örneklemeyle kalır** — §23-24
  ölçümleri onunla alındı, değiştirilirse ölçümler geçersizleşir.
  Yeniden üretim aksiyonları da yeniden yazar; işaretli aksiyon varsa
  kullanıcıya sorulur.
- Her map-reduce parçası için **yeni `LanguageModelSession`** aç; oturumu
  tekrar kullanırsan geçmiş bağlamı yiyip 4096'yı taşırır.
- **Noktalama istemine konuşmacı öneki ("Ben:", "Katılımcı:") EKLEME.**
  Ölçüldü (RESEARCH.md §15.1): önekli istem 8 denemenin 6'sında
  `guardrailViolation` veriyor, öneksiz 8/8 geçiyor. Özetleme isteminde önek
  sorun çıkarmıyor ve **korunmalı** — kimin neyi üstlendiğini oradan çıkarıyor.
- `guardrailViolation` gerçek ve tekrarlayan bir durumdur; her LLM çağrısı
  başarısızlığa dayanıklı olmalı. Noktalama başarısız olursa **orijinal metin
  korunur** — model kelime değiştirirse o satır reddedilir (normalize edilmiş
  karşılaştırma). Noktalama bir iyileştirmedir, kelime kaybetme pahasına yapılmaz.
- Özetleme isteminde **"'Ben' bu kaydı tutan kişidir"** cümlesi bulunmalı;
  yoksa `kisi` alanı hep "belirtilmedi" geliyor. Kullanıcı adını ayarlardan
  verdiyse cümleye eklenir (`OraSettings.userDisplayName`).
- **Diarization olmadığı için uzaktaki katılımcılar ayırt edilemez.** Kanal
  ayrımı yalnızca "Ben" ve "Katılımcı" verir; `kisi` çoğu zaman
  "belirtilmedi" olur. Bu bilinçlidir — kendinden emin yanlış bir ad, boş bir
  alandan kötüdür.
- Konu başlıkları `@Generable` şema ile alınır; düz metin istenirse model
  numaralı liste ve açıklama döküyor.
- Model karar/aksiyonları tekrarlayabiliyor — çıktı normalize edilmiş
  karşılaştırmayla tekilleştirilir.

## Toplantı Algılama Kuralları — ölçülmüş davranış
- **`ps aux` polling'i yok.** Sinyal CoreAudio olay dinleyicileridir:
  `kAudioHardwarePropertyProcessObjectList` + her süreç için
  `kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`.
  `AudioObjectAddPropertyListenerBlock` ile olay tabanlı, izin gerekmiyor,
  CPU maliyeti sıfıra yakın (doğrulandı, bkz. RESEARCH.md §9).
- **Toplantı tanımı:** bilinen bir toplantı uygulaması **mikrofonu kullanıyor**
  (`isRunningInput == true`). Uygulamanın açık olması yetmez — eski ora'nın
  temel hatası buydu. Aynı anda `isRunningOutput` da varsa güven yükselir.
- Süreç listesi değiştiğinde dinleyiciler **yeniden bağlanır** (yeni süreçler
  otomatik izlenmez).
- Uygulama kimliği `NSWorkspace.shared.runningApplications` ile eşlenir
  (pid → bundleID, görünen ad, ikon). İzin gerekmez. **Alt-dize eşleşmesi
  kullanma** — tam bundle ID karşılaştır (eski ora'da `if app not in output`
  Slack Helper süreçlerinde bile tutuyordu).
- **Tek istisna, mikrofon sahibi:** Electron/WebView uygulamalarında mikrofonu
  ana süreç değil yardımcı süreç tutar. `MeetingApps.resolve(_:)` gözlenen
  kimliği **`bilinen + "."`** ön ekiyle ana uygulamaya çözer. Bu alt-dize
  eşleşmesi değildir (nokta sınırı zorunlu) ve yukarıdaki kuralla çelişmez:
  o kural "uygulama açık mı" testi içindi, bu test "mikrofonu tutuyor mu"
  (RESEARCH.md §28.2).
- **Dışlama listesi zorunlu.** Gözlenen yanlış pozitif: `com.apple.CoreSpeech`
  sistem TTS/dikte sırasında mikrofonu açık gösteriyor. Varsayılan dışlananlar:
  `com.apple.CoreSpeech`, Siri, kendi bundle ID'miz. Liste ayarlardan düzenlenebilir.
- **Titreşim engelleyiciler:** mikrofon en az 10 sn kesintisiz kullanılmalı
  (mikrofon testi gibi anlık kullanımları eler); uygulama başına soğuma süresi
  (varsayılan 30 dk).
- **İzinsiz otomatik kayıt yok.** Algılama yalnızca *önerir*. Kullanıcı bir
  uygulama için "her zaman kaydet" derse o uygulamada otomatik başlar.
- **Algılama bildirim iznini beklemez.** Ölçüldü (RESEARCH.md §17.2):
  `requestAuthorization` istemi kullanıcı yanıtlayana kadar askıda kalıyor;
  beklenirse algılama hiç başlamıyor. Bildirim gönderilemediğinde öneri
  arayüzdeki şeritte gösterilir — tek yüzeye bağlı kalınmaz.
- **Otomatik durdurma:** toplantı uygulaması mikrofonu 30 sn'den uzun bıraktıysa
  kaydı bitirmeyi öner (30 sn eşiği sessize alma senaryosunu yaşatır).
- **Tarayıcı toplantıları** (Chrome'da Google Meet): bundle ID tarayıcıdır,
  toplantı değil. Düşük güvenli algılama say ve öyle sun ("Chrome mikrofonu
  kullanıyor"). Sekme başlığı okumak ekran kaydı/erişilebilirlik izni ister —
  **isteme**.
- **Pencere başlığı yalnızca takvim eşleştirmesi için okunur**, opt-in
  (`windowTitleEnabled`, varsayılan kapalı) ve yalnızca Erişilebilirlik izni
  verilmişse. Başlık hiçbir yere yazılmaz. Kapalıyken eşleştirme başlıksız
  çalışır, belirsizlikte sorar (§29.2-29.4).
- **Otomatik başlık pencere başlığından ÜRETİLMEZ.** `kCGWindowName` sandbox'lı
  uygulamada ekran kaydı izni ister — tap sayesinde kurtulduğumuz izni geri
  getirir. Başlık transkriptten Foundation Models ile üretilir; takvim
  entegrasyonu açıksa (EventKit, isteğe bağlı izin) etkinlik adı kullanılır.

## Takvim Entegrasyonu Kuralları
- **Opt-in, varsayılan kapalı.** Ayarlardan açılır; kapalıyken EventKit'e hiç
  dokunulmaz ve izin istenmez.
- Okumak `requestFullAccessToEvents` gerektirir (macOS 14+). **ora takvime asla
  yazmaz** — `NSCalendarsFullAccessUsageDescription` metni bunu açıkça söyler:
  "ora toplantı adını ve katılımcıları okumak için takviminize erişir.
  Takviminize hiçbir şey yazmaz ve hiçbir veri cihazınızdan çıkmaz."
- **Kullanıcı hangi takvimlerin dahil olacağını seçer.** Varsayılan: hiçbiri
  seçili değil, kullanıcı iş takvimini seçer. Kişisel takvimi taramaya zorlama.
- **Dar pencere:** yalnızca `now − 12 saat … now + 24 saat` sorgulanır.
  Takvim toplu taranmaz, geçmiş arşiv okunmaz.
- **Katılımcı filtresi zorunlu:**
  `participantType == .person` (oda ve kaynaklar elenir) **ve**
  `participantStatus != .declined`. Bu filtre olmadan "Toplantı Odası 3"
  katılımcı olarak kaydedilir.
- Takvim değişiklikleri `EKEventStoreChangedNotification` ile dinlenir — polling yok.
- **Eşleştirme puanlıdır, "ilk bulunan" değil** (RESEARCH.md §29). ±10 dk
  penceresindeki adaylar elenir (iptal edilmiş etkinlik aday değildir) ve
  puanlanır: pencere başlığı eşleşmesi +6, toplantı linki mikrofonu tutan
  uygulamayla aynıysa +3, başlangıca 5 dk içinde +3, sürüyorsa +2, kabul
  ettiysem +2, organizatörsem +2, **reddettiysem −3** (elenmez — insan
  reddettiği toplantıya katılabiliyor). Tepe aday ikinciyi 3 puan geçemezse
  **tahmin edilmez, kullanıcıya sorulur**; cevap gelene kadar katılımcı ve
  başlık yazılmaz. Sözlük de ancak seçim kesinleşince beslenir.
- **Yanlış eşleşme sonradan düzeltilebilir:** kenar çubuğu bağlam menüsünde
  "Takvim toplantısını değiştir". Eski `source='calendar'` katılımcıları
  silinir, `source='transcript'` satırlarına dokunulmaz.
- **Katılımcı adları vocabulary'ye beslenir** ve `DictationTranscriber`'a
  `ContentHint.customizedLanguage` ile verilir. Özel isimler tanımanın en zayıf
  noktasıdır; bu, takvimin en somut teknik kazancıdır.
- **Başlık önceliği:** takvim etkinlik adı → yoksa Foundation Models'ın
  transkriptten ürettiği başlık → yoksa tarih/saat. Pencere başlığı okunmaz.
- **DB'ye yalnızca gerekli olan yazılır:** etkinlik kimliği, başlık, katılımcı
  adları. `notes`, `location` ve etkinlik gövdesi **kopyalanmaz** — orası
  kullanıcının takviminde kalır.
- Toplantı linki (`event.URL` veya `notes`) yalnızca **hangi uygulamanın
  tap'leneceğini** belirlemek için ayrıştırılır, saklanmaz.

## Güç ve Termal
Ayrı bir "Low Power Mode" alt sistemi **yoktur** — eski ora'da bu özellik
WhisperX+LLM'in dakikalarca CPU'yu meşgul etmesi yüzünden vardı. Yeni ölçümlerle
gerekçesi kalmadı: canlı transkripsiyon tek çekirdeğin %1'i, kayıt sonrası geçiş
60 dakikalık toplantıda ~2 dakika.

Yerine iki satırlık kontrol:
```swift
ProcessInfo.processInfo.isLowPowerModeEnabled     // sistem düşük güç modu
ProcessInfo.processInfo.thermalState              // .serious / .critical
```
İkisinden biri doğruysa kayıt sonrası özetlemeyi otomatik başlatma, kullanıcıya
Türkçe bir bildirimle sor. Şarj durumu izleme, `IOPSCopyPowerSourcesInfo`,
"Şarja Takılıyken" ayarı — hiçbiri yazılmaz.

## Database Schema (açık talimat olmadan değiştirme)
```sql
meetings(id, title, date, duration, status, template, audio_path,
         calendar_event_id, created_at)
  -- calendar_event_id: EKEvent.eventIdentifier, takvim kapalıysa NULL
transcripts(id, meeting_id, speaker, channel, text, start_time, end_time, confidence, created_at)
  -- transcripts.channel: 'mic' | 'system'
action_items(id, meeting_id, person, task, context, deadline, status, created_at)
  -- context: işin neden çıktığı, tek cümle. Boşsa NULL
  -- status: 'pending' | 'done' — kullanıcı arayüzden işaretler
vocabulary(id, word, source, status, rejected_until, added_date)
  -- vocabulary.status: 'active' | 'pending' | 'rejected'
corrections(id, mistake, correct, meeting_id, created_at)
chat_history(id, meeting_id, question, answer, timestamp)
participants(id, name, email, meeting_count, last_seen)
  -- email: yalnızca kişi eşleştirme (dedupe) için; arayüzde gösterilmez,
  --        cihazdan çıkmaz. Takvim kapalıysa NULL
meeting_participants(meeting_id, participant_id, source, role)
  -- source: 'calendar' | 'transcript'   role: 'organizer' | 'attendee' | NULL
  -- PRIMARY KEY(meeting_id, participant_id)
topic_segments(id, meeting_id, title, bullets JSON, start_time, end_time)
  -- bullets: konunun maddeleri. Konu **başlık listesi değil**, notun gövdesi
summaries(id, meeting_id UNIQUE, overview JSON, decisions JSON, created_at)
  -- overview: madde listesi (v4 öncesi düz metin; tek maddelik listeye düşer)
transcripts_fts -- FTS5 virtual table (text, speaker), insert/delete/update trigger'ları
```
**Tarih sütunları** GRDB'nin varsayılan biçiminde yazılır
(`YYYY-MM-DD HH:MM:SS.SSS`, UTC).

**v4'te kaldırılan sütunlar:** `meetings.health_score`, `summaries.next_meeting`,
`summaries.sentiment`, `summaries.talk_share`, `summaries.dead_air_pct`. İlk üçü
hiç doldurulmuyordu; son ikisi yazılıp hiç okunmuyordu (konuşma payı arayüzden
kaldırıldı, bkz. UI Kuralları).

**Silme davranışı:** `meetings` satırı silinince `transcripts`, `summaries`,
`action_items`, `topic_segments` cascade ile gider ve FTS trigger'ı indeksi
temizler (doğrulandı, RESEARCH.md §16.2). `corrections` **silinmez**, yalnızca
`meeting_id` NULL olur — kullanıcının düzeltme bilgisi toplantıya bağlı değildir.
Önceki ora'ya göre eklenenler ve gerekçeleri:
- `transcripts.confidence` — Speech API `.transcriptionConfidence` veriyor
- `meetings.calendar_event_id` — takvim etkinliğiyle bağ
- `participants.email` — aynı adlı kişileri ayırt etmek için; **arayüzde
  gösterilmez**, yalnızca eşleştirmede kullanılır
- `meeting_participants` — eski şemada `participants` global bir tabloydu ve
  hangi kişinin hangi toplantıda olduğunu tutmuyordu. Takvim katılımcıları
  bunu zorunlu kılıyor

**Neden SwiftData değil de SQLite:** ürünün merkezinde transkript içinde tam metin
arama var; SwiftData ve Core Data FTS sunmaz, `CONTAINS` yüklemleri tablo taraması
yapar ve saatlerce transkriptte çöker. Sistem SQLite'ında (3.51) FTS5 derlenmiş
durumda ve `unicode61` tokenizer Türkçe'yi doğru işliyor — doğrulandı: `İstanbul`
kaydı `istanbul` sorgusuyla eşleşiyor, `bütçe` diakritikleriyle bulunuyor.
Ayrıca SQLite dosyası taşınabilir, incelenebilir ve yedeklenebilir; %100 yerel
bir üründe kullanıcının kendi verisine erişebilmesi bir özelliktir.

## Dosya Yolları
- Uygulama verisi: `~/Library/Application Support/ora/`
- Ses kayıtları:   `{base}/recordings/{meeting_id}.wav`
  (sıkıştırma açıksa işlem sonrası `.m4a` olur ve `meetings.audio_path`
  güncellenir; ölçüm RESEARCH.md §25.3 — 11,5× kazanç, kanal ayrımı korunuyor)
- Veritabanı:      `{base}/ora.sqlite`
- Loglar:          `{base}/logs/ora.log`
Yolu asla sabit yazma — `FileManager.default.urls(for:.applicationSupportDirectory)`.

## UI Kuralları
- UI kodu yazmadan önce **BRAND.md** oku
- SwiftUI; ikonlar SF Symbols
- Düzen: `NavigationSplitView` kenar çubuğu 240-300pt + orta panel
  (sekmeler: **Özet | Transkript**). Sohbet, orta panelin **içinde** 320 pt'lik
  katlanabilir bir bölmedir — `.inspector` **kullanılmaz**: üçüncü sütun
  açıldığında orta sütun ~655 pt'nin altına inmediği için SwiftUI kenar
  çubuğunu pencerenin dışına itiyordu (RESEARCH.md §26.2).
  "Konuşmacılar" sekmesi yoktur (DESIGN.md §4)
- **Özet sırası: Kişiler → Aksiyonlar → Genel bakış → Kararlar → Konular.**
  Aksiyon önce gelir; kullanıcının toplantı notuna ilk sorusu "bana ne düştü"
- **Pencere minimumu sohbet paneline göre değişir** (900 → 940, ölçüldü) ve `Window`
  sahnesinde `.windowResizability(.contentMinSize)` ile sert sınır yapılır.
  Bu olmadan `NavigationSplitView` + `.inspector` sığmadığında kenar çubuğunu
  pencerenin dışına taşıyıp kırpıyor (§24.5)
- **Kenar çubuğu araması bir simgedir**, sürekli duran alan kutusu değil;
  tıklanınca açılır, Escape kapatır. Toplantı kartı: başlık üstte, altında
  tarih-saat, sağ uçta süre
- **Oynatıcı ve ⌘F arama paneli yüzer** — kenardan kenara şerit çizmezler.
  Oynatıcıda kanal seçici yoktur; oynatma karışımdır
- **İlerleme çubuğu yoktur.** İşlem sürerken Özet sekmesinin tamamı ortalanmış
  `ProcessingState` olur: `CurveLoader` + yalnızca yüzde. Boş durumların düğmesi
  (Yeniden dene / Şimdi özetle) metnin altında ortalanır, tepede şerit yok
- **İşlem durumu toplantı başınadır** (`stages: [Int64: Stage]`), uygulama
  genelinde tek bir aşama değil. Animasyon yalnızca **işlenen toplantı
  seçiliyken** görünür (`isProcessingSelected`); yetki kapıları "herhangi bir
  toplantı işleniyor mu"ya bakar (`isTranscribing`). Hattın ürettiği içerik
  arayüze yalnızca o toplantı ekrandayken yazılır, veritabanına her hâlükârda.
  Aşama **veritabanından türetilmez** — tek kaynağı hattın kendisidir
  (RESEARCH.md §27)
- **Konuşma payı / ölü hava kartı yoktur.** Kanal başına iki kova kişi bilgisi
  taşımıyordu ve okuma akışını kesiyordu; `MeetingMetrics` kaldırıldı
- Gradyan yok
- Gölge en fazla: `.shadow(color: .black.opacity(0.08), radius: 3, y: 1)`
- Köşe yarıçapı en fazla 8
- Geçişler en fazla 150ms ease
- Tüm modal'lar Escape ile kapanır
- `.accessibilityReduceMotion` desteklenir

## İzinler (Info.plist) — eksikse uygulama sessizce çöker
- `NSMicrophoneUsageDescription` — Türkçe açıklama
- `NSSpeechRecognitionUsageDescription` — Türkçe açıklama
- `NSCalendarsFullAccessUsageDescription` — yalnızca takvim özelliği açıksa
  istenir; metin "yazmaz, veri çıkmaz" güvencesini içerir
- `NSAudioCaptureUsageDescription` — sistem sesi tap'i için (ekran kaydı izni DEĞİL)
- **App Sandbox KAPALI** (RESEARCH.md §29.4). Çakışan takvim toplantılarını
  ayırmanın tek yerel yolu pencere başlığını okumak ve Erişilebilirlik API'si
  sandbox'ta başka süreçler için çalışmıyor — izin istemi bile çıkmıyor.
  Dolayısıyla `com.apple.security.*` yetkileri kaldırıldı; mikrofon ve takvim
  TCC ile (yukarıdaki Info.plist metinleri) sorulmaya devam ediyor.
  Eski kural — "takvim için `personal-information.calendars` yetkisi şart"
  (§19) — yalnızca sandbox'lı derlemeler için geçerliydi.
- **Ağ girişi yok ve eklenmeyecek.** Kural #3'ün (hiçbir veri cihazı terk
  etmez) yapısal garantisi buydu; sandbox kalksa da entitlement listesinde ağ
  yok. Dağıtım .dmg + Developer ID, Mac App Store hedeflenmiyor.
- **Erişilebilirlik izni opt-in.** `OraSettings.windowTitleEnabled` varsayılan
  **kapalı**; kapalıyken `WindowTitle`'a hiç dokunulmaz ve izin istenmez.
  Onboarding'de ve Ayarlar → Takvim'de açılabilir.
- Sistem sesi izni reddedilirse yalnız-mikrofon moduna düş, çökme

## Hata Yönetimi
- Asla sessizce çökme — tüm hatalar kullanıcıya **Türkçe** ulaşır
- Speech hatası: ham sesi koru, sonradan elle tekrar denemeye izin ver
- Foundation Models kullanılamıyorsa: transkript yine de üretilir ve gösterilir,
  yalnızca özet devre dışı kalır — uygulama işlevsiz kalmaz
- Tüm hatalar `{base}/logs/ora.log` dosyasına yazılır (`OSLog` + dosya köprüsü)

## Git Kuralları
- Çalışan her özellikten sonra commit — istisnasız
- Biçim: `feat: [Türkçe açıklama]`
- main'e bozuk kod gitmez
- Dal adlandırma: `feature/audio-capture`, `feature/speech` vb.

## Referans Dokümanlar — Her Oturumda Oku
- **RESEARCH.md** — hangi API'nin Türkçe'de gerçekten çalıştığını gösteren
  ölçümler ve tekrar çalıştırılabilir probe'lar. Bir API hakkında şüpheye
  düşersen `probes/` altındaki dosyayı çalıştır, tahmin yürütme.
- **ROADMAP.md** — hangi özellik, hangi fazda
- **ARCHITECTURE.md** — modüller arası sözleşmeler
- **FALLBACK.md** — Apple yığını yetmezse ne yapılacağı (whisper.cpp yolu)
- **BRAND.md** — UI kodu yazmadan önce
- **COMPETITION.md** — rakip incelemesi ve önceliklendirilmiş iyileştirme
  listesi. Faz 8 ve sonrası buradan besleniyor; "hangi rakipte var → ora'da
  neye karşılık gelir → hangi kuralla çakışır" biçiminde

### Geliştirme Verisi
Gerçek bir toplantıyla denetim için `probes/bordro_toplanti.json` (29 dk'lık
Teams dökümü) `scripts/seed-transcript.swift` ile veritabanına yüklenir.
Uygulamada içe aktarma **yoktur**; bu yalnızca geliştirme aracıdır. Yükledikten
sonra toplantıyı seçip "Şimdi özetle" demek uygulamanın kendi hattını koşturur.

**Dikkat:** bu dosyadaki metin **Teams'in transkripsiyonudur**, ora'nın değil.
Sesi de yoktur. Bu toplantıda görülen çözümleme hataları ("Toplum"←Toplam,
"matığın"←matrahının, "Düdük tut", 12 adet `Işsizlik`←İşsizlik) Teams'e aittir;
özetleme ya da Apple Speech değerlendirilirken bu veriye bakıp ora'nın
transkripsiyonu hakkında sonuç çıkarma. Yalnızca **özetleme hattını** denemek
için kullanılır.

### Bu Dosyayı Güncel Tutma Kuralı
CLAUDE.md'de yazan bir yaklaşımdan **daha iyisi için** vazgeçildiyse
(kütüphane, algoritma, mimari karar, izin modeli), CLAUDE.md **aynı commit'te**
güncellenir. Kural tamamen geçersizleştiyse sil — "eskiden şöyleydi" notu bırakma.

## Ne YAPILMAMALI
- Gereksiz SPM paketi ekleme (GRDB dışında bir şey eklemeden önce sor)
- Herhangi bir bulut API'si kullanma
- Windows/Linux için soyutlama katmanı yazma — kapsam dışı
- Kayıt sırasında Speech veya LLM çalıştırma
- Transkripti karakter sınırıyla kırpma — parçala
- BRAND.md dışında hex renk kullanma
- Uygulama adını küçük harf "ora" dışında yazma
- Oturumun kapsamı dışında özellik ekleme

## Current Session Status
[x] Her yeni oturumun başında güncelle:
    - Çalışan: **Faz 1 — İskelet**. `ora.xcodeproj` (objectVersion 77, senkronize
      klasör grubu), SwiftUI App, macOS 26.0 hedefi, sandbox + ad-hoc imza,
      GRDB 7.11.1 çözüldü. `AppPaths`, `Log` (OSLog + dosya köprüsü),
      asset kataloğunda BRAND paleti, `NavigationSplitView` + `.inspector`
      boş pencere. Uygulama açılıyor, günlük yazıyor, hiçbir şey kaydetmiyor.
      **Faz 2 — Ses Yakalama** tamam: mikrofon (`AVAudioEngine`) + sistem sesi
      (CoreAudio süreç tap'i → özel toplama cihazı → IOProc), host time ile
      hizalanmış artımlı stereo WAV, yalnız-mikrofon düşüşü, çökme kurtarma,
      `liveBuffers` akışı. Gerçek kayıtla doğrulandı — RESEARCH.md §13.
      **Faz 3 — Transkripsiyon** tamam: `SpeechAnalyzer` + `DictationTranscriber`,
      kanal başına ayrı geçiş, kelime zamanı + güven skoru, `AssetInventory` ile
      dil paketi indirme, sessiz kanal atlama, güven skoruna dayalı otomatik dil
      seçimi, canlı mod (`.volatileResults`). Ölçümler RESEARCH.md §14.
      **Faz 4 — Foundation Models** tamam: `availability` kapısı, zorunlu
      noktalama adımı (kelime koruma güvenceli), map-reduce özetleme
      (`@Generable Ozet`), konu başlıkları, hesaplanmış sağlık metrikleri.
      50.000 karakterlik transkript 6 parçada ~55 sn (RESEARCH.md §15).
      **Faz 5 — Depolama, Arama, UI** tamam: GRDB şeması + migration'lar,
      FTS5 + trigger'lar, toplantı listesi ve arama, düzeltme, silme,
      Markdown/PDF/e-posta dışa aktarımı (RESEARCH.md §16).
      **Faz 6 — Akıllı Katman** tamam: özel sözlük (ölçülmüş `weight 1.0`),
      CoreAudio olay tabanlı toplantı algılama, eylemli bildirimler + arayüz
      şeridi, otomatik durdurma önerisi, toplantı sohbeti, otomatik başlık,
      güç/termal ertelemesi, EventKit takvim entegrasyonu (opt-in).
      Ölçümler RESEARCH.md §17.
      **Çıktı yapısı Circleback referansına göre yenilendi (RESEARCH.md §23):**
      konu blokları artık gövdeli (başlık + maddeler) — eskiden gövde üretilip
      birleştirmede çöpe gidiyordu; genel bakış madde listesi; aksiyonlarda
      gerekçe satırı ve onay kutusu; parça sınırı 10.000 → 6.000 karakter
      (gerçek oran 2,45 krk/token, eski sınır pencereyi taşırıyordu).
      **Faz 7 — Paketleme** tamam: uygulama ikonu, `MenuBarExtra` (taşıyıcı yüzey),
      kayıt sırasında kırmızı nokta ve kanal seviyeleri, ilk açılış onboarding'i,
      `scripts/build-release.sh` ile 3,7 MB .dmg (RESEARCH.md §18).
      **Faz 8 — Elimizdekini Kullan** tamam (kaynağı COMPETITION.md):
      ses oynatıcı (kanal seçici · hız · satır senkronu), toplantılar arası
      aksiyon panosu, özet maddesinden transkripte alıntı bağı (IDF ağırlıklı
      eşleştirme), arama parçacığı ve ⌘F, depolama yönetimi (AAC 11,5×,
      saklama süresi), gerçek global kısayol, satır silme ve konuşmacı
      etiketi düzeltme, kayıt bildirimi hatırlatıcısı. Yeni bağımlılık, yeni
      izin ve **şema değişikliği yok**. Ölçümler RESEARCH.md §25.
      **Toplantı geçişi düzeltildi (RESEARCH.md §27):** işlem durumu artık
      toplantı başına tutuluyor; A özetlenirken B'ye geçince animasyon B'ye
      taşınmıyor, A'ya dönünce hemen görünüyor ve A'nın özeti B'nin ekranına
      düşmüyor. `probes/meeting_switch.swift` bunu gerçek denetleyiciyle ölçer.
      **Gerçek kayıtla uçtan uca doğrulandı (RESEARCH.md §22):** kayıt sonrası
      tam geçiş `AVAudioFile.read`'in dosya sonundaki `nilError`'ı yüzünden her
      kayıtta düşüyordu; düzeltildi. Başarısız veya yarım kalmış bir toplantı
      artık **"Yeniden dene"** düğmesiyle ham sesten yeniden işlenir.
    - Bekleyen:
      1. **Faz 0** — gerçek toplantı sesiyle doğruluk kapısı. İlk gerçek
         (TTS olmayan) örnek alındı (§14.2, güven 0.76–0.86) ama kısa.
      2. **İmzalama ve notarizasyon** — makinede kod imzalama kimliği yok;
         Apple Developer üyeliği gerekiyor. Betik hazır, ek kod gerekmiyor.
      3. ~~Gerçek bir Teams/Zoom toplantısıyla algılama→kayıt akışı denenmedi.~~
         **Tamamlandı (RESEARCH.md §28.3-28.5):** mikrofonu ve sesi Teams'in
         yardımcı süreçleri tutuyor; algılama ve tap hedefleme buna göre
         düzeltildi. Teams test aramasıyla uçtan uca doğrulandı — kapsamlı
         tap'ten ch1 tepe 0,69, kanal ayrımı ve iki kanallı transkripsiyon
         doğru, gözcü devreye girmedi. Zoom'la denenmedi.
    - **Sparkle (otomatik güncelleme) kullanıcı kararıyla eklenmedi.** Tek
      bağımlılık GRDB olarak kalıyor.
    - **Bilinen geliştirme engeli:** uygulama ad-hoc imzalı. İmza her derlemede
      değiştiği için TCC mikrofon iznini **her derlemede** yeniden soruyor,
      Dock/Cmd+Tab ikonu yer tutucu gösteriyor (RESEARCH.md §20) ve
      **bildirim izni hiç alınamıyor** — `Notifications are not allowed for
      this application`; sıfırdan yazılmış ad-hoc bir uygulamayla doğrulandı
      (RESEARCH.md §28.1). Bu yüzden geliştirme derlemelerinde öneri yalnızca
      penceredeki şeritte görünür.
      **Kendinden imzalı sertifika çözüm değil** — Gatekeeper reddediyor ve
      uygulama hiç açılmıyor (§21). Çözüm Apple Developer Program üyeliğidir.

### Proje Düzeni (Faz 1'de kuruldu)
```
ora.xcodeproj          — senkronize klasör grubu: ora/ altına eklenen dosya
                         otomatik derlemeye girer, pbxproj elle düzenlenmez
Config/Info.plist      — izin metinleri (INFOPLIST_FILE ile bağlı)
Config/ora.entitlements— sandbox KAPALI (§29.4); ağ girişi YOK (kural #3'ün garantisi)
ora/oraApp.swift       — @main + AppDelegate (dizin hazırlığı, açık mod sabiti)
ora/Core/              — AppPaths, Log, OraError, MeetingMetrics, OraSettings,
                         PowerState, AudioArchive (boyut/sıkıştırma/silme),
                         GlobalHotKey (⌘⇧R, Carbon)
ora/Detect/            — MeetingDetector (CoreAudio olay dinleyicileri)
ora/Calendar/          — CalendarReader (EventKit, opt-in)
ora/Capture/           — AudioCapture (orkestra), MicrophoneCapture,
                         SystemAudioTap, StereoRecordingWriter, AudioClock,
                         RecordingRecovery, MeetingApps, Channel
ora/Transcribe/        — SpeechTranscription (tam geçiş), LiveTranscription,
                         TranscriptionLocale (dil + otomatik seçim), Segment,
                         TranscriptIndex (özet maddesi → transkript eşleştirme)
ora/Intelligence/      — FoundationIntelligence (noktalama + map-reduce özet),
                         Ozet (@Generable şemalar), TranscriptChunker, Intelligent
ora/Store/             — OraDatabase (şema + migration), MeetingStore (tek kapı),
                         Records (GRDB kayıtları), VocabularyStore
ora/UI/                — Color+Ora (palet belgesi + OraStyle), RootView,
                         MenuBarView (taşıyıcı yüzey), OnboardingView,
                         RecordingController, MeetingSidebar, MeetingDetail,
                         TranscriptView, SummaryView, ActionBoardView,
                         AudioPlayback (+ PlaybackBar), MeetingExport, SettingsView,
                         MeetingNotifications, ChatInspector,
                         EmptyState (+ ProcessingState), CurveLoader, FlowLayout
ora/Resources/Assets.xcassets/Colors    — BRAND paletinin tek kaynağı
ora/Resources/Assets.xcassets/AppIcon   — scripts/make-icon.swift üretir
scripts/               — make-icon.swift (ikon), build-release.sh (arşiv → .dmg)
probes/meeting_switch.swift — gerçek `RecordingController` ile toplantı geçişi
                         denetimi (uygulama kaynaklarıyla derlenir; başlıkta
                         komut var)
```
Renkler asset kataloğundadır; `Color.oraPaper` gibi semboller derleme zamanında
üretilir. Elle `Color("oraPaper")` yazma — yanlış isim derlenmez olsun.
