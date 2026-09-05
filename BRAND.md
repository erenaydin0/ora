# ora — Marka Kimliği (native)

ora’nın kimliği **ağız ve sözdür** (Latince *ora*). Uygulama katmanı yerel
SwiftUI’dir; palet ve işaret de buna göre kurulur — önceki Electron ürününün
mavi/kayısı vurgu sistemi **devralınmaz**.

## Marka Özü
- Ad: ora (Latince: söz, ağız) — her zaman küçük harf
- Slogan: "Sesi bilgiye dönüştürür"
- Aura: Sıcak, yerel, odaklı — kâğıt üzerinde bir ağız
- Vaat: Toplantıdaki konuşmayı cihazda bilgiye çevirir; veri çıkmaz

## Renk Paleti
| Rol | Ad | Hex | Token |
|---|---|---|---|
| Kağıt — ana tuval | Paper Cream | `#FAF6F0` | `.oraPaper` |
| Kağıt — kenar şerit | Chrome Cream | `#F3ECE1` | `.oraChrome` |
| Nötr hover | Quiet Gray | `#F5F5F7` | `.oraGray` |
| Metin | Slate Black | `#333333` | `.oraInk` |
| İkincil metin | — | `#888888` | `.oraInkMuted` |
| Marka / vurgu | Carmine | `#A61B2B` | `.oraCarmine` |
| Marka — dudak / kavite | Carmine Deep | `#6B121C` | `.oraCarmineDeep` |
| Kayıt durumu | Active Red | `#E53935` | `.oraRed` |
| Kart / panel içi | Pure White | `#FFFFFF` | `.oraSurface` |
| Kenarlık | Soft Border | `#E8E8E8` | `.oraBorder` |

**Uygulamanın vurgu rengi (`AccentColor`) Carmine’dir.** Anahtarlar, sekme
seçimi, varsayılan (default) butonlar ve bağlantı stili bunu alır. macOS’un
sistem mavisi hiçbir yerde görünmez.

Üç kırmızı **aynı işi yapmaz**:
- **Carmine** — kimlik: işaret, native vurgu, ilerleme, sohbet soru çizgisi,
  tamamlanmış onay.
- **Carmine Deep** — yalnızca işaretin dudağı ve kavitesi. Arayüzde başka yerde yok.
- **Active Red** — yalnızca canlı kayıt (buton, menü bar noktası, kenar çubuğu
  kayıt noktası). Parlak ve alarm; Carmine’den açıkça ayrılır.

Kenar çubuğu seçimi Carmine **yıkanmaz** — macOS seçimi soldurur ve kayıt
kırmızısıyla karışır. Seçili satır `.oraChrome` kâğıt karttır.

Bağlantı da Carmine’dir (AccentColor). Metadata (kişi, tarih, konuşmacı)
`.oraInkMuted` kalır; ikinci bir vurgu rengi açılmaz.

Bu tablo tek kaynaktır. Renkler `Resources/Assets.xcassets/Colors` içinde
**bir kez** tanımlanır; `Color.oraPaper` gibi token’lar derleme zamanında
üretilir. Görünümlerde ham hex veya `Color(red:green:blue:)` yazılmaz.

## Tipografi
**Sistem fontu kullanılır — font paketlenmez, indirilmez.** Gövde ve başlık
`SF Pro` (SwiftUI’da `.system(...)`), transkript sistem monospace
(`.system(.body, design: .monospaced)`).

Gerekçe: SF Pro Türkçe diakritikleri (ı İ ğ Ğ ş Ş) eksiksiz taşır, uygulama
boyutuna sıfır ekler ve macOS’un metin ölçekleme/erişilebilirlik ayarlarına
kendiliğinden uyar. Marka kimliğini renk, boşluk ve işaret taşır; özel font değil.

| Kullanım | Boyut | Ağırlık | Renk |
|---|---|---|---|
| Gövde metni | 14 | Regular | `.oraInk` |
| Bölüm başlığı | 13 | Medium, uppercase + letter-spacing | `.oraInk` |
| Küçük etiket | 12 | Regular | `.oraInkMuted` |

## Logo Kuralları
- Uygulama adı **her zaman** küçük harf: **ora**
- Asla: Ora, ORA, O.R.A.
- Wordmark: "ora", SF Pro Medium, `.oraInk` — onboarding’de işaretin yanında
- Uygulama ikonu ve `OraLogo`: kenardan kenara **Carmine** zemin. İşaret konuşan
  bir ağızdır:
  - Carmine Deep — dudak (hacim)
  - Paper Cream badem — açıklık (söz)
  - Açıklığın alt kenarında Deep yarık — kavite (dinleme)
  - Sağdaki krem damla — sesin bilgiye dönüşmesi
- Gradyan yok, yazı yok, ses çubuğu yok. macOS 26 köşeyi kendi çizer; sanat
  eseri kare ve doludur (RESEARCH.md §20).
- `OraLogo` köşe yarıçapı en fazla 8’dir; Dock kabuğunu taklit etmez.

## UI Kişiliği
- Bol boşluk, dekoratif öğe yok
- Gradyan **yok**
- Gölge en fazla: `.shadow(color: .black.opacity(0.08), radius: 3, y: 1)`
- Köşe yarıçapı en fazla 8
- İkonlar: SF Symbols, **tek renk** (`.symbolRenderingMode(.monochrome)`) —
  başka ikon seti yok
- Animasyon: yalnızca ince, en fazla `.easeOut(duration: 0.15)`
- Düz yazı içinde kalın başlık kullanma
- Yoğunluk: rahat, sıkışık değil — cömert padding

## Bileşen Renk Kuralları
- Birincil / varsayılan buton: sistem stili, AccentColor = Carmine, açık metin
- İkincil buton: `.oraSurface` zemin, `.oraInk` metin, `.oraBorder` kenarlık
- Kenar çubuğu: saat omurgası (solda saat, sağda başlık). Seçili satır
  `.oraChrome` şerit, `.oraInk` metin — kart yığını değil.
- Sohbet araç çubuğu: kapalıyken `.oraInk` çizgi, açıkken dolu `.oraCarmine`
  simge — renkli zemin yok
- Yıkıcı eylem: `.oraRed` (sistem destructive)
- Kayıt: **yalnızca** `.oraRed`, aktifken nabız
- Onay / hazır: `.oraCarmine` (kayıt kırmızısı değil)
- İşlem göstergesi: **ilerleme çubuğu yoktur.** Ekranın ortasında `CurveLoader`
  (Lissajous 3:2 eğrisi üzerinde `.oraCarmine` parçacık) ve altında yalnızca
  yüzde. Parçacığın izi geriye doğru sönerek çizilir — bu bir gradyan değil,
  **hareketin izidir**; "gradyan yok" kuralının kapsamı dışındadır ve tek
  istisnadır. `.accessibilityReduceMotion` açıkken eğri durur
- Sol kenar çubuğu + araç çubuğu: **native malzeme**. `.oraChrome` marka
  yüzeylerinde: onboarding üst şeridi, öneri bantları, boş durum kartları
- Ana panel + sohbet paneli + pencere zemini: `.oraPaper`
- Kart / panel: `.oraSurface` zemin, ince `.oraBorder`
- Katılımcı ve aksiyon sahibi çipi: baş harfler `.oraChrome` daire üzerinde
  `.oraInk`. **Kişi başına renk açılmaz** — metadata `.oraInkMuted`/`.oraInk`
  kalır, ikinci bir vurgu rengi yoktur
- Aksiyon onay kutusu: boşken `.oraInkMuted` çember, işaretliyken dolu
  `.oraCarmine` (onay/hazır Carmine'dir, kayıt kırmızısı değil).
  Tamamlanan satırın metni `.oraInkMuted`'a düşer

Pencere arka planı (`NSWindow.backgroundColor` / `.containerBackground`) tuvalle
**aynı** olmalı. Başlık çubuğunda trafik ışığı boşluğu şeffaf bırakılmaz.

## Ne YAPILMAMALI
- Active Red’i (`#E53935`) kayıt bağlamı dışında kullanma
- Carmine Deep’i işaret dışında kullanma
- Kenar çubuğu seçimini Carmine veya Active Red ile boyama
- Sohbet ve boş durum simgelerinde çok renkli / palet SF Symbol kullanma
- Saf siyah (`#000000`) kullanma — her zaman Slate Black (`#333333`)
- Aynı ekranda ikiden fazla font ağırlığı kullanma
- Dekoratif illüstrasyon veya stok fotoğraf ekleme (işaret bunun istisnası değil:
  UI’da extra çizim yok; işaret yalnızca ikon ve `OraLogo`)
- Gradyan kullanma
- Uygulama adını küçük harf "ora" dışında yazma
- Eski paleti (Core Blue `#1A56A3`, Soft Apricot `#F7C79A`) geri getirme
