# ora — Rakip İncelemesi ve İyileştirme Listesi

> Tarih: 2026-09-05. Kaynaklar dosyanın sonunda.
> Bu dosya bir özellik dilekçesi değil, **karar listesidir**: her madde
> "hangi rakipte var → ora'da neye karşılık gelir → hangi dosyaya dokunur →
> hangi kuralla çakışır" biçiminde yazıldı. CLAUDE.md'deki kurallarla
> çakışan maddeler §6'da ayrı tutuldu; oradan hiçbir şey sessizce alınmaz.

---

## 1. İncelenen uygulamalar ve ora'ya göre konumları

| Uygulama | Model | Yakalama | Gizlilik | ora için asıl ders |
|---|---|---|---|---|
| **Granola** | Not defteri + AI zenginleştirme | Bot yok, cihaz sesi | Bulut, SOC 2; **ses saklanmaz** | Ürünün merkezi *kullanıcının kendi notu*. AI notu yazmaz, kullanıcının notunu büyütür |
| **Circleback** | Tam otomatik not + otomasyon | Bot **veya** masaüstü | Bulut, SOC 2 + HIPAA | Aksiyon takibi bir *sonuç* değil, ürünün kendisi: atama, durum, hatırlatma |
| **Fathom** | Tam otomatik, kayıt saklanır | Bot yok | Bulut | Ses/video geri oynatma ve klip paylaşımı; cömert ücretsiz katman |
| **Otter** | Canlı transkripsiyon | Zoom/Meet entegre | Bulut | Canlı altyazı, klasör, vurgulama, işbirlikli düzenleme |
| **Fireflies** | Toplantı zekâsı | Bot | Bulut | Toplantılar **arası** sohbet (AskFred), Soundbites (klip) |
| **Hyprnote** | Yerel-öncelikli, açık kaynak | Cihaz sesi | %100 yerel (Ollama/LM Studio) | ora'nın en yakın rakibi. Şablon sistemi ve "memo + özet" akışı |
| **MacWhisper** | Yerel transkripsiyon aracı | Dosya + sistem sesi | %100 yerel | Sürükle-bırak içe aktarma, toplu işleme, izlenen klasör, **diarization (beta)**, zengin dışa aktarım (SRT/DOCX/CSV) |
| **Bluedot / tl;dv** | Satış odaklı | Bot/uzantı | Bulut | Şablon + CRM; ora için ilgisiz ama şablon fikri geçerli |

**Konumlandırma sonucu:** ora'nın rakiplerden ayrıldığı üç yer —
(1) tamamen cihaz üstü ve **sıfır çalışma zamanı** (7,7 MB uygulama; Hyprnote
bile Ollama/LM Studio istiyor), (2) **Türkçe birinci sınıf dil**, (3) **iki
kanallı kayıt** (mic/sistem ayrı). Üçüncüsü henüz ürün değerine
çevrilmedi — §4'teki en iyi fikirlerin çoğu oradan çıkıyor.

---

## 2. ora bugün nerede duruyor

**Rakiplerle eşit veya önde:** bot yok, cihaz sesi tap'i (ekran kaydı izni
istemeden), canlı transkript, map-reduce özet, konu blokları, aksiyonlar,
toplantı sohbeti, FTS5 arama, takvim eşleştirme, otomatik algılama, vocabulary.

**Rakiplerde standart olup ora'da hiç olmayanlar** (kod tabanında doğrulandı):
1. **Ses oynatma yok.** WAV diskte duruyor, `AVAudioPlayer` kodda geçmiyor.
   Kelime düzeyi zaman damgası üretiliyor ama yalnızca konu → transkript
   atlamasında kullanılıyor.
2. **Toplantılar arası hiçbir görünüm yok.** Aksiyon panosu, kişi sayfası,
   klasör/etiket yok. `participants` / `meeting_participants` tabloları
   yazılıyor ama arayüzde karşılığı yalnızca `PeopleStrip`.
3. **Kullanıcının kendi notu yok.** Granola'nın tüm ürünü bu.
4. **Şablon yok.** `meetings.template` sütunu var, her satıra `"general"`
   yazılıyor, hiçbir yerde okunmuyor.
5. **Arama parçacığı gösterilmiyor.** `MeetingStore.snippets(for:search:)`
   yazılmış, hiçbir View çağırmıyor.
6. **Depolama yönetimi yok.** 16 kHz/16 bit/stereo ≈ **saatte 230 MB**;
   haftada 10 saat toplantı ayda ~9 GB. Silme/sıkıştırma/politika yok.
7. **Diarization yok.** Bu yüzden `kisi` alanı çoğu aksiyonda
   "belirtilmedi" — ürünün en görünür kalite açığı.

---

## 3. Öncelik sırası (özet)

| # | İş | Etki | Efor | Yeni bağımlılık |
|---|---|---|---|---|
| 1 | ✅ Ses oynatıcı + transkript senkronu | ★★★ | S | yok |
| 2 | ✅ Açık aksiyonlar panosu (toplantılar arası) | ★★★ | S | yok |
| 3 | ✅ Alıntı bağı: her madde → transkript → ses | ★★★ | S | yok |
| 4 | ✅ Arama parçacığı + toplantı içi arama | ★★ | XS | yok |
| 5 | ✅ Depolama yönetimi (AAC'ye çevir / eski sesi sil) | ★★ | S | yok |
| 6 | Kullanıcı notu + not zenginleştirme (Granola modeli) | ★★★ | M | yok |
| 7 | Toplantı şablonları | ★★ | M | yok |
| 8 | Kanal başına dil (mic tr / sistem en) | ★★★ | S | yok |
| 9 | Kayıt sırasında "önemli an" işareti | ★★ | S | yok |
| 10 | Toplantılar arası sohbet (FTS ile daraltılmış) | ★★★ | M | yok |
| 11 | Kişi sayfası + tekrarlayan toplantı hazırlığı | ★★ | M | yok |
| 12 | Hatırlatıcılar / Kısayollar (App Intents) çıkışı | ★★ | M | yok |
| 13 | Diarization | ★★★ | L | **karar gerek** |
| 14 | Ses dosyası içe aktarma | ★★ | M | **karar gerek** |
| 15 | Kayıt öncesi tampon ("başlatmayı unuttum") | ★★ | M | **karar gerek** |

S ≈ yarım–bir gün, M ≈ birkaç gün, L ≈ hafta.

---

## 4. Maddelerin ayrıntısı

### 4.1 Ses oynatıcı + transkript senkronu — *en ucuz büyük kazanç*
**Rakip:** Fathom, Otter, Paxo, MacWhisper. Granola bilerek yapmıyor (sesi
saklamıyor); ora sesi zaten saklıyor, yani bedavaya gelen bir özelliği
kullanmıyor.
**Ne:** Transkript sekmesinde alt bar: oynat/duraklat, hız (1×/1,5×/2×),
kaydırma çubuğu. Segmente tıkla → oradan çal; oynarken aktif satır vurgulanır.
**Kanal düğmesi ora'ya özel:** *Karışım · Yalnız ben · Yalnız karşı taraf*.
İki kanallı yazımın kullanıcıya ilk kez görünür değeri budur — gürültülü
kayıtta karşı tarafı tek başına dinlemek transkripti doğrulamanın en hızlı yolu.
**Nerede:** `ora/UI/TranscriptView.swift` (+ yeni `ora/UI/AudioPlayback.swift`),
`Segment.start`. `AVAudioPlayer` + `AVAudioPCMBuffer` kanal ayıklaması; yeni
bağımlılık yok.
**Yan kazanç:** `transcripts.confidence` bugün yazılıyor ama okunmuyor —
güveni düşük satırları çok hafif bir işaretle göster, tıklayınca o an çalsın.
Düzeltme akışı (çift tıkla) böylece kendi kendini hedefler ve `corrections` →
vocabulary döngüsü gerçekten beslenir.

### 4.2 Açık aksiyonlar panosu
**Rakip:** Circleback (atama + tamamlanma takibi), Fireflies.
**Ne:** Kenar çubuğuna toplantıların üstünde ikinci bir kök: **Aksiyonlar**.
Tüm toplantılardan `status = 'pending'` olanlar; gruplama: *Bana düşenler /
Başkalarında / Tarihi geçmiş*. Satıra tıkla → kaynak toplantıya git.
**Neden:** DESIGN.md zaten "kullanıcının ilk sorusu 'bana ne düştü'" diyor ve
özet sırası buna göre kuruldu. Ama soru **toplantı açıldığında** değil,
sabah uygulamayı açtığında soruluyor. Bugün o cevap hiçbir ekranda yok.
**Nerede:** `MeetingStore` (tek sorgu), `MeetingSidebar`, yeni `ActionsView`.
Şema değişikliği gerekmiyor — `action_items` tablosu yeterli.

### 4.3 Alıntı bağı (citations)
**Rakip:** Granola ("çift tıkla, kaynağı gör"), Circleback.
**Ne:** Aksiyon ve karar maddeleri de konu blokları gibi transkriptteki yerine
atlasın; oradan 4.1'in oynatıcısı devreye girsin.
**Nasıl (LLM'e sormadan):** Zaman aralığı modelden **istenmez** — konu
bloklarında olduğu gibi, maddeyi üreten parçanın segment aralığı taşınır.
İsteğe bağlı hassaslaştırma: madde metnindeki karakteristik kelimeleri o
parçanın segmentlerinde ara, en iyi eşleşen segmenti seç (yerel, ucuz, LLM yok).
**Şema:** `action_items` ve `summaries.decisions`'a `start_time` eklenmesi
gerekir — v5 migration. Bugünkü `decisions` JSON'u düz metin listesi.

### 4.4 Arama parçacığı ve toplantı içi arama
`snippet(transcripts_fts, …)` sorgusu yazılmış, çağıran yok. Sonuç satırında
eşleşme parçacığını göster; ayrıca transkript sekmesinde ⌘F ile toplantı içi
arama + sonraki/önceki eşleşme. FTS5 `highlight()` ile vurgulama.
**Efor:** XS. Zaten yazılmış SQL'i arayüze bağlamak.

### 4.5 Depolama yönetimi
**Rakip karşılaştırması:** Granola sesi hiç saklamıyor, Fathom saklıyor ve
saklama süresini yönetiyor. ora saklıyor ve **yönetmiyor** — bu bir hata modu.
**Ne:** Ayarlar → Depolama: toplam boyut, en büyük toplantılar,
- "Transkripsiyon bittikten sonra sesi AAC'ye çevir" (≈10× kazanç, `AVAssetExportSession`)
- "N günden eski ses dosyalarını sil" (transkript ve özet kalır)
- Toplantı bağlam menüsünde "Yalnızca sesi sil".
**Dikkat:** Ses silinince "Yeniden dene" yolu kapanır — arayüz bunu söylemeli.

### 4.6 Kullanıcı notu + zenginleştirme — *Granola'nın çekirdeği*
**Ne:** Kayıt sırasında (ve sonrasında) kullanıcının kendi kaba maddelerini
yazdığı bir alan. Kayıt bitince özetleyici, kullanıcının notunu **iskelet**
olarak alır: kullanıcının yazdığı maddeler korunur, transkriptten gelen
ayrıntı altlarına eklenir. Granola bunu görsel olarak da ayırıyor (kullanıcı
metni koyu, AI eklemesi gri) — ora'da `.oraInk` / `.oraInkMuted` karşılığı hazır.
**Neden ora'ya uyar:** Kural #1'i ihlal etmez — kayıt sırasında yalnızca
**yazı yazılır**, LLM çağrısı yok. Ve 3B modelin en zayıf yanını kapatır:
neyin önemli olduğuna model karar vermek zorunda kalmaz.
**Şema:** `meetings.user_notes TEXT` (v5) — veya zaman damgalı notlar için
küçük bir `notes(id, meeting_id, text, at_time)` tablosu. Zaman damgalı olması
4.3'ün alıntı bağını nota da getirir.
**Prompt:** Birleştirme aşamasında kullanıcı notu ayrı bir blok olarak verilir;
4096 token penceresi için not uzunluğu sınırlanmalı (ölçülmeli).
**Yüzey:** Canlı modda transkriptin yanında ikinci sütun ya da `.inspector`
içinde "Notlarım" sekmesi (sohbet paneliyle aynı yerde, çakışmadan).

### 4.7 Toplantı şablonları
**Rakip:** Granola (keşif görüşmesi, bire bir, standup…), Hyprnote, Bluedot.
**Ne:** `meetings.template` sütunu zaten var. 5 Türkçe şablon yeter:
*Genel · Bire bir · Müşteri görüşmesi · Ürün/sprint · Mülakat*.
Şablon, `@Generable` şemayı değiştirmez — **talimatı** ve hangi bölümlerin
istendiğini değiştirir (ör. bire birde "kararlar" yerine "gelişim konuları";
mülakatta "aday değerlendirmesi"). Takvim açıksa etkinlik adından şablon
tahmini önerilebilir ("1:1", "sync", "mülakat").
**Nerede:** `FoundationIntelligence` talimat üretimi + `MeetingDetail` başlık
şeridinde şablon seçici + "Bu şablonla yeniden özetle".

### 4.8 Kanal başına dil — *rakiplerde olmayan, mimariden bedava gelen özellik*
Yabancı müşteriyle toplantıda kullanıcı Türkçe, karşı taraf İngilizce
konuşuyor. ora iki kanalı **zaten ayrı** `SpeechAnalyzer` ile çözüyor
(`SpeechTranscription`), ama ikisine de aynı locale veriliyor.
**Ne:** Ayarlarda "Mikrofon dili" ve "Sistem sesi dili" ayrı seçilebilsin
(varsayılan: ikisi de aynı / Otomatik). Otomatik seçim mantığı kanal başına
zaten koşturulabilir — `TranscriptionLocale`'daki güven karşılaştırması
kanal başına çağrılır.
**Efor:** S. Granola'nın "multi-language" özelliğinin ora'daki karşılığı ve
tek kanallı rakiplerin yapısal olarak yapamayacağı bir şey.

### 4.9 Kayıt sırasında "önemli an" işareti
**Rakip:** Fireflies Soundbites, Otter highlight.
**Ne:** Kayıt sırasında menü barından veya kısayolla (⌘⇧M) o anı işaretle.
İşaret `notes` tablosuna zaman damgasıyla düşer; transkriptte küçük bir
işaret olarak görünür ve özet isteminde "kullanıcı bu anları işaretledi"
bağlamı olarak kullanılır.
**Neden:** Kayıt sırasında LLM çalıştırmadan, kullanıcının dikkatini
modele taşımanın en ucuz yolu. 4.6'nın küçük kardeşi; önce bu yapılabilir.
**Bonus:** İşaretli aralığı `.m4a` olarak dışa aktar → Soundbites'ın yerel karşılığı.

### 4.10 Toplantılar arası sohbet ve arama
**Rakip:** Fireflies AskFred, Granola "klasörlerle sohbet".
**Sorun:** 4096 token penceresiyle "tüm toplantılarımda ara" naif biçimde
yapılamaz.
**Çözüm (yerel RAG):** FTS5 zaten var. Soru → anahtar kelimeler → FTS5 ile
aday segmentleri getir (BM25 sıralı, ilk N) → yalnız onları map-reduce'a ver.
`FoundationIntelligence`'ın "ilgisiz parçaları YOK ile ele" mantığı
korunur, ama artık 60 toplantıyı değil 20 segmenti tarar.
**Yüzey:** Kenar çubuğunda toplantı seçili değilken `.inspector` "tüm
toplantılarda sorun" moduna geçer. Yanıtta kaynak toplantı satırları
(4.3'ün alıntı bağıyla) listelenir.

### 4.11 Kişi sayfası ve tekrarlayan toplantı hazırlığı
**Rakip:** Granola "Briefs" (gece hazırlanan toplantı brifingi), Circleback,
Town/Vimcal.
**Ne (yerel ve LLM'siz kısmı):** Bir kişiye tıklayınca: onunla yapılan
toplantılar, ona atanmış açık aksiyonlar, son toplantının kararları.
Takvim açıkken menü bardaki "sıradaki toplantı" satırı bu kartı gösterir:
*"Aynı katılımcılarla son toplantı 12 Ağustos — 3 açık aksiyon, 2 karar."*
**Ne (LLM'li kısmı, isteğe bağlı):** Toplantıdan 10 dk önce kısa bir hazırlık
notu üret. Kural #1'i ihlal etmez (kayıt yok). Ama pil/termal kontrolü
`PowerState` üzerinden aynen uygulanmalı.
**Şema:** Yeni tablo gerekmez; `meeting_participants` + `action_items` yeterli.

### 4.12 Hatırlatıcılar ve Kısayollar (App Intents)
**Rakip:** Circleback'in "automations" + 1000 uygulama entegrasyonu.
**ora'nın yerel karşılığı:** ağ olmadan, cihazda:
- **Hatırlatıcılar'a gönder:** aksiyon maddesi → Reminders (EventKit,
  ayrı bir izin ve ayrı bir liste; **takvime yazma yasağı bundan ayrıdır**,
  ama aynı özenle opt-in olmalı ve Info.plist metni yazılmalı).
- **Apple Notes'a gönder:** özet → Notes (Shortcuts/AppleScript).
- **App Intents:** "Son toplantının özetini ver", "Kaydı başlat/durdur".
  Kısayollar ve Spotlight'tan çağrılabilir; sıfır bağımlılık, tamamen Apple yerel.
**Neden:** Rakiplerin bulut otomasyonlarının ora'da mümkün olan tek biçimi bu
ve kural #3'ü hiç zorlamıyor.

### 4.13 Diarization — **karar gerektirir**
**Durum:** ora'nın en büyük kalite açığı. Kanal ayrımı yalnızca
"Ben / Katılımcı" veriyor; uzak taraftaki 4 kişi tek isim altında.
Bu yüzden aksiyonlardaki `kisi` çoğunlukla "belirtilmedi" ve ürünün en
değerli çıktısı (kime ne düştü) yarım kalıyor.
**Seçenekler:**
1. **FluidAudio** (Apache 2.0, CoreML, ANE üzerinde çalışıyor, macOS 13+).
   Hazır, bakımlı, hızlı. **Ama ikinci SPM bağımlılığı** ve model dosyası
   indirmesi getirir — CLAUDE.md'nin "tek bağımlılık GRDB / model indirme yok"
   kuralına iki yerden dokunur. **Sormadan yapılmaz.**
2. **Kendi kümelemesi:** yalnızca sistem kanalında, konuşmacı değişimini
   VAD + basit gömme kümelemesiyle yakalamak. Bağımlılık yok, doğruluk düşük,
   iş yükü yüksek.
3. **Yapmamak** ve bunun yerine kullanıcının katılımcı adlarını (takvimden)
   **elle** segmentlere atamasına izin vermek — transkriptte satır seçip
   "Bu Ayşe" demek. Ucuz, dürüst, hiç yanlış tahmin yok. Vocabulary'yi de besler.
**Öneri:** Önce 3'ü yap (bir gün), sonra gerçek bir Teams kaydında 1'i
`probes/` altında ölç (DER). Ölçüm olmadan bağımlılık eklenmesin.

### 4.14 Ses dosyası içe aktarma — **karar gerektirir**
**Rakip:** MacWhisper'ın çekirdeği (sürükle-bırak, toplu işleme, izlenen klasör).
**Ne:** Var olan bir `.wav/.m4a/.mp3` dosyasını toplantı olarak içe al,
transkripsiyon + özet hattını koştur. Tek kanal olduğu için "Katılımcı"
konuşmacısı; diarization yoksa tek etiket.
**Çakışma:** CLAUDE.md "Uygulamada içe aktarma **yoktur**" diyor — ama bu
cümle `probes/bordro_toplanti.json` transkript seed'i bağlamında yazıldı.
Ses içe aktarma ayrı bir karardır; alınırsa CLAUDE.md aynı commit'te güncellenmeli.
**Değeri:** Telefonla kaydedilmiş yüz yüze toplantı, eski kayıt arşivi.
Kullanıcı tabanı için gerçek bir talep; kapsamı da küçük (hat zaten hazır).

### 4.15 Kayıt öncesi tampon — **karar gerektirir**
**Ne:** "Kaydı başlatmayı unuttum" sorunu. Algılama zaten mikrofonu izliyor;
opsiyonel olarak son 3 dakikayı diskte dairesel bir tamponda tut, kayıt
başlayınca öne ekle.
**Neden ora'ya yakışır:** Algılama altyapısı (CoreAudio dinleyicileri) hazır;
rakiplerin çoğunda bu yok (Limitless/Rewind hariç).
**Risk:** "Sürekli dinleyen uygulama" algısı ora'nın gizlilik duruşuyla
gerilim yaratır. Yapılırsa: **varsayılan kapalı**, onboarding'de açıkça
anlatılan, menü barda görünür bir gösterge, tampon RAM'de değil
`{base}/buffer/` altında ve kayıt başlamazsa 3 dakikada üzerine yazılan.

### 4.16 Küçük ama görünür işler
- **Gerçek global kısayol:** `MenuBarView`'daki ⌘⇧R bir menü kısayolu;
  uygulama ön planda değilken çalışmaz. Gerçek global kısayol
  (`RegisterEventHotKey` veya `NSEvent` global monitor) rakiplerde standart.
- **Klasör / etiket:** Granola'nın klasörleri. Minimal karşılık: toplantıya
  etiket + kenar çubuğunda etikete göre filtre. Küçük tablo, büyük düzen kazancı.
- **Transkript satırı silme:** Granola 2026'da ekledi (yanlış duyulan özel
  bilgi, araya karışan konuşma). ora'da düzeltme var, silme yok.
- **Konuşmacı etiketini düzeltme:** yalnız-mikrofon modunda her şey "Ben"
  olarak damgalanıyor; kullanıcı satırı "Katılımcı"ya çevirebilmeli.
- **Kayıt bildirimi metni:** rakipler bunu "consent" özelliği olarak satıyor.
  ora'nın yerel karşılığı: ayarlarda "Kaydı başlatınca beni uyar" +
  panoya kopyalanabilir Türkçe anons cümlesi. KVKK açısından da doğru davranış,
  ve maliyeti bir onay kutusu.
- **Zengin dışa aktarım:** MacWhisper'ın SRT/VTT/DOCX/CSV listesi. ora için
  anlamlısı: **SRT** (video ile eşleştirme), **CSV** (aksiyonlar), düz metin.
- **Demo toplantı:** ilk açılışta örnek bir toplantı göstermek. `scripts/
  seed-transcript.swift` zaten var; uygulama içi bir "örneği göster" düğmesi
  ilk 5 dakikayı boş ekrandan kurtarır.

---

## 5. Türkçe hendeği — hiçbir rakibin yatırım yapmadığı alan

Rakiplerin hepsi "100+ dil" diyor; hiçbiri Türkçe için ölçüm yapmıyor.
ora'nın savunulabilir farkı burada büyüyebilir:

1. **Karışık dil (code-switching) ölçümü.** "Sprint'i deploy ettik" gibi
   cümlelerde `DictationTranscriber(tr-TR)` ne yapıyor? Ölçülmedi.
   `probes/` altında bir deneme, sonuç RESEARCH.md'ye.
2. **Sayı, tarih, para normalizasyonu.** "beş yüz bin lira" → "500.000 TL",
   "on beşinde" → tarih. Noktalama adımı zaten var; aynı geçişte
   yapılabilir ama **kelime koruma güvencesi** (değişirse satırı reddet)
   burada gevşetilmeli, o yüzden ayrı ve isteğe bağlı bir adım olmalı.
3. **Kurum/ürün sözlüğü.** Vocabulary bugün düzeltmelerden ve takvim
   katılımcılarından besleniyor. Eklenebilir: kullanıcının kendi şirket
   sözlüğü (ayarlarda liste) — `count = 30` sınırı ölçüldü, seçim
   sıklığa göre yapılmalı.
4. **Faz 0 hâlâ açık.** Gerçek Türkçe toplantı sesinde WER ölçülmedi.
   Yukarıdaki maddelerin çoğu transkript kalitesinin üstüne bina ediliyor;
   bu kapı kapanmadan büyük yatırım yapmak riskli. **Sıradaki iş bu olmalı.**

---

## 6. Rakiplerde var, ora'ya **alınmayacak** olanlar

Bunlar CLAUDE.md'nin kurallarıyla çakışır; listeye "yapılmadı" diye değil,
"bilerek yapılmıyor" diye giriyor:

- **Toplantıya bot gönderme** (Circleback, Fireflies, Otter) — cihaz sesi
  yakalama zaten daha iyi ve izinsiz.
- **Bulut senkronizasyonu, hesap, ekip çalışma alanı, paylaşılan klasör**
  (Granola, hepsi) — kural #3. Paylaşım yalnızca dışa aktarımla.
- **CRM / Slack / Notion entegrasyonları** — ağ yok. Yerel karşılığı §4.12.
- **Telemetri, kullanım analitiği** — kapsam dışı.
- **Video kaydı ve klip paylaşımı** (Fathom) — ROADMAP kapsam dışı.
- **Windows/Linux** (Hyprnote Q1 2026'da yapıyor) — kapsam dışı.
- **Canlı altyazı yayını** (Otter'ın Zoom'a altyazı basması) — başka
  uygulamanın penceresine yazmak gerekir; izin modeli ora'nın duruşuna aykırı.

---

## 7. Önerilen faz planı

**Faz 8 — "Elimizdekini kullan" (yeni bağımlılık yok, yeni izin yok)** ✅
4.1 oynatıcı · 4.2 aksiyon panosu · 4.3 alıntı bağı · 4.4 arama parçacığı ·
4.5 depolama · 4.16'dan global kısayol, satır silme, konuşmacı etiketi,
kayıt uyarısı. *Hepsi var olan veriyi ve var olan SQL'i arayüze bağladı;
şema değişmedi.* Ölçümler RESEARCH.md §25.

**Faz 9 — "Not defteri" (ürün kimliği)**
4.6 kullanıcı notu + zenginleştirme · 4.9 önemli an · 4.7 şablonlar ·
4.8 kanal başına dil.
*ora burada "otomatik özetleyici"den "toplantı defteri"ne döner —
Granola'nın kazandığı yer burası, ve ora bunu bulutsuz yapabilir.*

**Faz 10 — "Toplantılar arası"**
4.10 çapraz sohbet (FTS-RAG) · 4.11 kişi sayfası + hazırlık · 4.12 App Intents
+ Hatırlatıcılar · 4.16 etiketler.

**Paralel ve önce başlaması gereken:** §5.4 Faz 0 doğruluk kapısı ve
4.13'ün ölçümü. Bunlar özellik değil, karar verisi.

---

## Kaynaklar

- [Circleback — The 7 Best AI Meeting Assistants in 2026](https://circleback.ai/blog/best-ai-meeting-assistants)
- [Fathom vs. Granola (2026)](https://www.fathom.ai/vs/granola)
- [Granola — AI-enhanced notes (Docs)](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Granola — Changelog / Updates](https://www.granola.ai/updates)
- [Granola — Pricing, plans, features](https://www.granola.ai/blog/granola-pricing-plans-features-roi)
- [Granola — AI notetaker participant privacy & consent](https://www.granola.ai/blog/ai-notetaker-participant-privacy-consent)
- [alternativeto — Granola shared folders, AI citations](https://alternativeto.net/news/2025/5/granola-launches-new-collaborative-shared-folders-ai-citations-and-advanced-model-support)
- [Circleback — Recording consent for AI meeting notes](https://circleback.ai/blog/recording-consent-for-ai-meeting-notes)
- [Hyprnote (GitHub)](https://github.com/faryid/hyprnote) · [Hyprnote incelemesi](https://www.blog.brightcoding.dev/2026/02/17/hyprnote-the-private-ai-notepad-revolutionizing-meetings)
- [8 Best Local AI Meeting Note Takers for Mac (2026)](https://heymumble.com/blog/local-ai-meeting-note-takers-mac)
- [MacWhisper — changelog, pricing, Pro features (2026)](https://whipscribe.com/tools/macwhisper)
- [Fireflies vs Otter karşılaştırması](https://www.sybill.ai/blogs/fireflies-vs-otter-ai)
- [FluidAudio — Swift/CoreML diarization](https://github.com/FluidInference/FluidAudio)
- [Zapier — What is Granola](https://zapier.com/blog/granola-ai/)
