# ora — Marka Kimliği (native)

Renkler, ton ve kişilik önceki ora'dan **birebir devralındı** — bu bir yeniden
markalama değil, aynı ürünün yerel yeniden yazımıdır. Değişen tek şey
uygulama katmanı: Tailwind sınıfları yerine SwiftUI `Color` token'ları,
Lucide yerine SF Symbols.

## Marka Özü
- Ad: ora (Latince: söz, ağız)
- Slogan: "Sesi bilgiye dönüştürür"
- Aura: Güvenilir, minimalist, akıllı, odaklanmış, %100 yerel
- Vaat: Toplantılardaki karmaşayı netliğe kavuşturur

## Renk Paleti
| Rol | Ad | Hex | Token |
|---|---|---|---|
| Kağıt — ana tuval | Paper Cream | `#FAF6F0` | `.oraPaper` |
| Kağıt — kenar şerit | Chrome Cream | `#F3ECE1` | `.oraChrome` |
| Nötr vurgu / hover | Quiet Gray | `#F5F5F7` | `.oraGray` |
| Metin & tipografi | Slate Black | `#333333` | `.oraInk` |
| İkincil metin | — | `#888888` | `.oraInkMuted` |
| Vurgu | Core Blue | `#1A56A3` | `.oraBlue` |
| Vurgu / seçili zemin | Soft Apricot | `#F7C79A` | `.oraAccentSoft` |
| Kayıt durumu | Active Red | `#E53935` | `.oraRed` |
| Kart / panel içi | Pure White | `#FFFFFF` | `.oraSurface` |
| Kenarlık | Soft Border | `#E8E8E8` | `.oraBorder` |

**Uygulamanın vurgu rengi (`AccentColor`) `.oraAccentSoft`'tur.** macOS'un
varsayılan sistem mavisi hiçbir yerde kullanılmaz: liste seçimi, anahtarlar,
sekme seçimi ve varsayılan butonlar bu yumuşak turuncuyu alır. Açık zeminde
AppKit etiket rengini kendiliğinden koyuya çevirdiği için her şey okunur kalır.

İki uyarı:
- **Doygunluk kasıtlı olarak yüksektir.** macOS kenar çubuğu seçimini
  soldurarak çizer; `#F5D0AE` gibi daha açık bir ton ekranda bej görünüyordu.
- **Active Red'e yaklaşmamalı.** `#E53935` yalnızca kayıt içindir; vurgu
  turuncusu ondan açıkça ayırt edilebilir kalmalı, aksi hâlde kayıt göstergesinin
  anlamı sulanır.

Core Blue (`.oraBlue`) vurgu değil **içerik** rengidir: bağlantı metni, aksiyon
sahibi adı, ilerleme göstergesi.

Bu tablo tek kaynaktır. Renkler `Resources/Assets.xcassets/Colors` içinde
**bir kez** tanımlanır; `Color.oraPaper` gibi token'lar asset kataloğundan
derleme zamanında üretilir. Görünümlerde ham hex veya `Color(red:green:blue:)`
yazılmaz.

## Tipografi
**Sistem fontu kullanılır — font paketlenmez, indirilmez.** Gövde ve başlık
`SF Pro` (SwiftUI'da `.system(...)`), transkript sistem monospace
(`.system(.body, design: .monospaced)`).

Gerekçe: SF Pro Türkçe diakritikleri (ı İ ğ Ğ ş Ş) eksiksiz taşır, uygulama
boyutuna sıfır ekler ve macOS'un metin ölçekleme/erişilebilirlik ayarlarına
kendiliğinden uyar. Marka kimliğini renk, boşluk ve ton taşır; font değil.

| Kullanım | Boyut | Ağırlık | Renk |
|---|---|---|---|
| Gövde metni | 14 | Regular | `.oraInk` |
| Bölüm başlığı | 13 | Medium, uppercase + letter-spacing | `.oraInk` |
| Küçük etiket | 12 | Regular | `.oraInkMuted` |

## Logo Kuralları
- Uygulama adı **her zaman** küçük harf: **ora**
- Asla: Ora, ORA, O.R.A.
- Başlık çubuğunda ve onboarding'de: "ora", SF Pro Medium, `.oraInk`

## UI Kişiliği
- Bol boşluk, dekoratif öğe yok
- Gradyan **yok**
- Gölge en fazla: `.shadow(color: .black.opacity(0.08), radius: 3, y: 1)`
- Köşe yarıçapı en fazla 8
- İkonlar: SF Symbols — başka ikon seti yok
- Animasyon: yalnızca ince, en fazla `.easeOut(duration: 0.15)`
- Düz yazı içinde kalın başlık kullanma
- Yoğunluk: rahat, sıkışık değil — cömert padding

## Bileşen Renk Kuralları
- Birincil buton: `.oraBlue` zemin, beyaz metin
- İkincil buton: `.oraSurface` zemin, `.oraInk` metin, `.oraBorder` kenarlık
- Aktif / seçili: `.oraAccentSoft` zemin, `.oraInk` metin — sistem seçimi de
  bu rengi kullanır (uygulama vurgu rengi olarak tanımlıdır)
- Yıkıcı eylem: `.oraRed`
- Kayıt butonu **yalnızca**: `.oraRed`, aktifken nabız animasyonu
- Sol kenar çubuğu + araç çubuğu: **native malzeme** (kendi rengimizi basmayız —
  DESIGN.md §5). `.oraChrome` yalnızca marka yüzeylerinde kullanılır:
  onboarding, hoş geldin ekranı, boş durum kartları
- Ana panel + sohbet paneli: `.oraPaper`
- Toplantı sağlık kartları: `.oraSurface` zemin, ince `.oraBorder`

Pencere arka planı (`NSWindow.backgroundColor`) tuvalle **aynı** olmalı;
aksi halde şerit ile tuval aynı renkmiş gibi algılanır. Başlık çubuğunda
trafik ışığı boşluğu şeffaf bırakılmaz.

## Ne YAPILMAMALI
- Active Red'i (`#E53935`) kayıt bağlamı dışında kullanma
- Saf siyah (`#000000`) kullanma — her zaman Slate Black (`#333333`)
- Aynı ekranda ikiden fazla font ağırlığı kullanma
- Dekoratif illüstrasyon veya stok fotoğraf ekleme
- Gradyan kullanma
- Uygulama adını küçük harf "ora" dışında yazma
