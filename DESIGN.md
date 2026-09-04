# ora (native) — Arayüz Tasarımı

Renk paleti, tipografi ve ton **BRAND.md**'de ve değişmedi. Bu dosya
*yapı* hakkında: hangi yüzeyler var, hangi an hangisine düşüyor, ve
eski ora'nın 3 sütunlu düzeninden nerede ayrılıyoruz.

Tasarımı değiştiren tek yeni gerçek şu: **canlı transkripsiyon artık bedava**
(tek çekirdeğin %1'i). Eski tasarım "toplantı bitti, şimdi okuyalım" üzerine
kuruluydu. Artık toplantı **sırasında** da gösterecek bir şeyimiz var, ve bu
yeni bir yüzey ihtiyacı doğuruyor.

---

## 1. Yüzeyler ve hangi anın kime ait olduğu

| An | Yüzey | Neden |
|---|---|---|
| Toplantı algılandı | **Bildirim** (`UNUserNotificationCenter`, eylemli) | Odağı çalmaz, her yerden aksiyon alınır, Odak modlarına saygılıdır |
| Kayıt sürüyor | **Menü bar** (`MenuBarExtra`) + isteğe bağlı **çentik HUD** | Her zaman görünür, tek tık durdurma |
| Toplantı sırasında detay | Ana pencere — **canlı mod** | İsteyen açar; açmayan menü barla yetinir |
| İşlem sürüyor | Menü bar rozeti + ana pencerede ilerleme | Sessiz bekleme yok |
| Özet hazır | **Bildirim** | Kullanıcı başka iştedir |
| Okuma / inceleme | Ana pencere — **arşiv modu** | Asıl iş burada |

### Algılama neden pencere değil bildirim
Eski ora ayrı bir sistem popup penceresi açıyordu (`popup.html`,
`popup-preload.js`). Bu üç sorun üretir: odak çalar, Odak/Rahatsız Etmeyin
modlarını dinlemez, ve toplantıya girerken ekranın ortasında beliren bir kutu
tam da en kötü zamanda gelir.

Eylemli bir bildirim aynı işi native yapar:
```
ora
Microsoft Teams toplantısı algılandı
[ Kaydet ]  [ Şimdi değil ]  [ Teams'i her zaman kaydet ]
```

**Takvim açıksa aynı bildirim çok daha iyi olur.** Mikrofon sinyali "bir
toplantı var" der, takvim "hangi toplantı" der:
```
ora
Q3 Bütçe Toplantısı  ·  14:00–15:00  ·  4 katılımcı
[ Kaydet ]  [ Şimdi değil ]  [ Bu toplantı serisini hep kaydet ]
```
Katılımcı adları bildirimde **gösterilmez** — omuz üstünden okunabilecek bir
yüzeydir. Sayı yeterli; adlar uygulama içinde kalır.

---

## 2. Menü bar — taşıyıcı yüzey

`MenuBarExtra` (SwiftUI, macOS 13+). **Sözleşme budur**; çentik yalnızca ek katman.

- **Boşta:** ora işareti, tek renk `.oraInk`
- **Kayıtta:** `.oraRed` nokta (BRAND kural #9 — kırmızı yalnızca burada ve kayıt butonunda)
- **İşlemde:** ince belirsiz ilerleme göstergesi
- **Tık → native menü** (`.menuBarExtraStyle(.menu)`), seçenekler alt alta:
  - durum satırı: `Kaydediliyor · 12:34` / `Toplantı işleniyor…` / `ora hazır`
  - **Kaydı başlat** veya **Kaydı durdur** (⌘⇧R)
  - kayıt sürerken canlı transkriptin son satırı
  - algılama önerisi varsa "… toplantısını kaydet" / "Şimdi değil"
  - "Pencereyi aç", "Ayarlar…", "ora'dan çık"
- **Takvim açıksa** menüde sıradaki toplantı: `Sıradaki: 14:00  Sprint Planlama`.
  Boştayken menü barın tek bilgi taşıdığı yer burasıdır — kayıt yokken bile
  uygulamanın bir işe yaradığını gösterir

> Önceki taslak burada özel çizilmiş bir popover (seviye çubukları dahil)
> öngörüyordu. Native menü tercih edildi: klavye gezinme, vurgulama ve kapanma
> davranışı bedava gelir ve menü çubuğundaki diğer uygulamalarla aynı hisseder.
> Kanal seviyeleri kayıt sırasında ana pencerede gösterilir.

---

## 3. Çentik HUD — ek katman, taşıyıcı değil

Geometri doğrulandı: bu makinede 179 × 32 pt (bkz. RESEARCH.md §10).
Çentik için **herkese açık bir API yok**; yapılan şey, çentiğin üstüne
konumlanmış kenarlıksız bir `NSPanel`'dir. Yükümlülükleri gerçek:

- `nonactivatingPanel` + `.statusBar` seviyesi — uygulamayı öne getirmemeli
- Boştayken `ignoresMouseEvents = true` — yoksa menü bar tıklamalarını yutar
- Tam ekranda menü bar gizlenir → HUD de gizlenmeli
- Harici monitörde ve çentiksiz Mac'te `auxiliaryTopLeftArea == nil` → menü bara düş

**Davranış:**
- **Yalnızca kayıt sırasında görünür.** Boşta hiçbir şey çizmez
- Toplu hâl: çentiğin sağına küçük `.oraRed` nokta + geçen süre
- Üstüne gelince aşağı doğru açılır: canlı altyazı satırı + Durdur
- Ayarlardan kapatılabilir; çentiği olmayan Mac'te ayar hiç görünmez

**Neden kayıt sırasında varsayılan açık:** kayıt yaptığını görünür kılmak bir
güven meselesidir. Boştayken görünmemesi de aynı sebeple — ekranın tepesinde
sürekli duran bir kutu değil, yalnızca bir şey olurken beliren bir gösterge.

---

## 4. Ana pencere — iki mod

### Yapı: native `NavigationSplitView` + `.inspector`
Araç çubuğu **kendi zeminini çizmez**
(`.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`): aksi hâlde beyaz
araç çubuğu ile krem tuval arasında yatay bir dikiş kalıyor. BRAND.md'nin
"pencere arka planı tuvalle aynı olmalı" kuralının bu düzendeki karşılığı budur.
Başlık çubuğunda düz "ora" metni yoktur; kimlik ikon, logo ve menü bardan gelir.

Eski ora üç sütunu elle kuruyordu (300px sabit sol, esnek orta, 320px sağ sohbet).
SwiftUI'da bunun native karşılığı var ve bedavaya sürükle-boyutlandırma,
katlama animasyonu, araç çubuğu düğmesi ve durum hatırlama getiriyor.

```
┌──────────────┬────────────────────────────┬───────────────┐
│ Sidebar      │ Content                    │ Inspector     │
│ 240–300pt    │ esnek                      │ katlanabilir  │
│ native malz. │ .oraPaper                  │ .oraPaper     │
│              │                            │               │
│ arama        │ Özet | Transkript          │ sohbet        │
│ toplantılar  │                            │               │
└──────────────┴────────────────────────────┴───────────────┘
```

Sohbet panelinin ayrı bir başlık şeridi **yoktur** — panelin kimliği araç
çubuğundaki düğmeden ve içeriğinden bellidir, başka hiçbir panelde böyle bir
etiket yok. Düğme `Toggle(.button)` stilindedir: panel açıkken basılı kalır,
açık olduğu düğmeden anlaşılır. Boş durum panelin **tamamına** göre ortalanır
(yazma alanı yüksekliği kadar yukarı kaymaz) ki kenar çubuğu ve orta paneldeki
boş durumlarla aynı hizada dursun.

**Sohbet paneli neden `.inspector`:** eski tasarımda 320px kalıcı olarak
ayrılmıştı. Sohbet ara sıra kullanılan bir araç; transkript ise sürekli okunan
metin. `.inspector` varsayılan kapalı gelir, açıldığında okunan metni daraltır
ama kalıcı vergi almaz.

### Sekmeler: **Özet | Transkript** (üç değil, iki)
Eskisi Özet | Transkript | Konuşmacılar idi. Kanal ayrımı sayesinde konuşmacı
sayısı pratikte iki ("Ben" / "Katılımcı") — bu bir sekmeyi hak etmiyor.
Konuşma payı, ölü hava ve katılımcı istatistikleri **Özet'in içinde kompakt bir
kart** olur; kullanıcı "ne oldu" sorusunu yanıtlarken bunlar zaten oradadır.

### Takvimin arayüzdeki yeri
- **Özet sekmesinin başında** kaynak rozeti: başlık takvimden geldiyse küçük bir
  takvim simgesi + etkinlik saati. Kullanıcı başlığın nereden geldiğini bilmeli
- **Katılımcılar** Özet içindeki kompakt kartta: takvimden gelenler ve
  transkriptte gerçekten konuşanlar **ayrı ayrı** gösterilir
  ("davetli 6 · konuşan 3"). Bu ayrım toplantının kimin için yapıldığını söyler
- **Toplantı listesinde** (kenar çubuğu) takvimden gelen toplantılar adıyla
  görünür; gelmeyenler LLM'in ürettiği başlıkla. Görsel ayrım yapılmaz —
  ikisi de meşru başlıktır
- Takvim kapalıyken bu yüzeylerin hiçbiri **yer tutmaz**; boş kart gösterme

### Canlı mod (yeni)
Kayıt sürerken pencere açıksa:
- Özet sekmesi yerine **"Kayıt sürüyor"** durumu: geçen süre, iki kanal seviyesi,
  Durdur
- Transkript sekmesi **canlı akar**; kesinleşmemiş metin `.oraInkMuted`,
  kesinleşince `.oraInk`'e döner. Bu ton farkı, canlı sonucun bir **ön izleme**
  olduğunu ve kayıt sonrası tam geçişte değişebileceğini kullanıcıya söyler
- Sohbet devre dışı (LLM kayıt sırasında çalışmaz — CLAUDE.md kural #1) ve
  nedeni Türkçe yazar: "Sohbet, toplantı bittikten sonra kullanılabilir"

---

## 5. Görsel dil — macOS 26 ile ilişki

macOS 26 yeni malzemeler getiriyor (`GlassButtonStyle`, `glassProminent`,
`backgroundExtensionEffect`). **Hepsini kullanmıyoruz.**

- **İçerik yüzeyi cam olmaz.** Transkript ve özet uzun metindir; ürünün asıl işi
  bunları okutmak. Krem kağıt (`.oraPaper`) okunabilirlik için seçildi ve kalıyor
- **Yüzen katmanlar cam olur:** çentik HUD'u, menü bar popover'ı. Semantiği
  "içeriğin üstünde yüzüyor" olan yerlerde native malzeme doğru cevap
- **Krom yüzeyler native malzemeye bırakılır:** kenar çubuğu ve araç çubuğu.
  Apple'ın kendi uygulamaları da böyle çalışır (Notlar: malzeme kenar çubuğu +
  kağıt içerik). Marka rengi içerikte, native davranış kromda

Bunun dışında BRAND.md aynen geçerli: gradyan yok, 8'den büyük köşe yok,
150ms'den uzun geçiş yok, `.oraRed` yalnızca kayıt.

---

## 6. Erişilebilirlik ve klavye
- Tüm modal'lar Escape ile kapanır
- `.accessibilityReduceMotion` — çentik açılma animasyonu ve nabız atan kayıt
  noktası bu durumda sabit hâle gelir
- Kayıt başlat/durdur için global kısayol (varsayılan ⌘⇧R)
- Kenar çubuğu araması `.searchable`, FTS5 destekli
- Canlı transkriptte VoiceOver kesinleşmemiş metni okumaz (sürekli değişir);
  yalnızca kesinleşen segmentler duyurulur

---

## 7. Bilinçli olarak yapılmayanlar
- Ayrı sistem popup penceresi (eski `popup.html`) — yerine eylemli bildirim
- Kalıcı sohbet sütunu — yerine `.inspector`
- "Konuşmacılar" sekmesi — istatistikler Özet'in içinde
- Boştayken görünen çentik göstergesi — yalnızca kayıt sırasında
- İçerik yüzeyinde cam/bulanıklık — okunabilirliğe zarar verir
- Takvim görünümü / ajanda ekranı — ora bir takvim uygulaması değil.
  Takvim yalnızca *besleyici*dir: başlık, katılımcı, sıradaki toplantı satırı.
  Kullanıcının takvimini ora içinde yönetmesine gerek yok
