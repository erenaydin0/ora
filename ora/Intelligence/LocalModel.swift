import Foundation

/// İndirilebilir özetleme modelleri ve diskteki durumları.
///
/// **Neden var:** Apple'ın cihaz üstü modeli referans notların olgularının
/// %20'sini yakalıyor ve bu tavan istem mühendisliğiyle kalkmıyor — üç tur
/// denendi (RESEARCH.md §33, §34, §35). Daha büyük bir yerel model tek geçişte
/// %38'e çıkarıyor (§37). Fark ücretsiz değil: 6 GB indirme, 7 GB tepe bellek,
/// iki kat süre. Bu yüzden **varsayılan değil, seçenek**.
///
/// Katalog **kapalıdır**: kullanıcı rastgele bir model kimliği giremez. Buradaki
/// her satır §37'nin tezgâhından geçmiştir; geçmemiş bir model eklenmez.
nonisolated struct LocalModel: Identifiable, Hashable, Sendable {

    /// Hugging Face deposu — indirme adresi ve kimlik aynı şey.
    let id: String
    let displayName: String
    /// İndirilecek yaklaşık boyut. Kullanıcıya sorulmadan 6 GB indirilmez.
    let downloadBytes: Int64
    /// İşlem sırasındaki tepe bellek (§37'de ölçüldü). Makinede bundan az
    /// varsa model **seçilemez**: yarıda kalan bir özet, olmayan özetten kötü.
    let peakMemoryBytes: Int64
    /// Bir toplantının tamamı tek isteme sığıyor mu — kazancın asıl kaynağı.
    let contextTokens: Int
    /// Ölçülen referans kapsaması (§37). Arayüzde gösterilir: kullanıcı neyin
    /// karşılığında 6 GB indirdiğini bilsin.
    let measuredCoverage: Int

    static let qwen35_9B = LocalModel(
        id: "mlx-community/Qwen3.5-9B-MLX-4bit",
        displayName: "Qwen3.5 9B",
        downloadBytes: 6_000_000_000,
        peakMemoryBytes: 7_200_000_000,
        contextTokens: 262_144,
        measuredCoverage: 38)

    /// Ölçülen ve kabul edilen modeller. Gemma 4 12B elendi (kapsama %12, en
    /// yavaş, 10,2 GB tepe bellek), Qwen3.5-4B güvenilir değil (iki
    /// toplantının birinde hiç çıktı vermedi) — ikisi de §37'de.
    static let catalog: [LocalModel] = [qwen35_9B]

    static func named(_ id: String) -> LocalModel? {
        catalog.first { $0.id == id }
    }

    var sizeLabel: String { AudioArchive.sizeLabel(downloadBytes) }
    var memoryLabel: String { AudioArchive.sizeLabel(peakMemoryBytes) }
}

/// Modelin diskteki hâli: kurulu mu, ne kadar yer kaplıyor, sil.
///
/// Dosyalar `{base}/models/` altında durur — ses kayıtlarıyla aynı veri
/// dizini, aynı kural (`AppPaths`, sabit yol yazılmaz). Kullanıcının diskindeki
/// 6 GB'ı uygulama görünmez bir yere saklamaz.
nonisolated enum LocalModelStore {

    /// `{base}/models/`
    static var directory: URL {
        AppPaths.base.appending(path: "models", directoryHint: .isDirectory)
    }

    /// Hugging Face önbellek düzeni: `models--<org>--<repo>/snapshots/<sha>/`.
    /// Biçimi biz seçmiyoruz, indirici dayatıyor; yol hesabı tek yerde dursun.
    static func directory(for model: LocalModel) -> URL {
        directory.appending(path: "models--" + model.id.replacingOccurrences(of: "/", with: "--"),
                            directoryHint: .isDirectory)
    }

    /// Ağırlıklar yerinde mi? Yarım inen bir dizin "kurulu" **sayılmaz**:
    /// yapılandırma ve en az bir ağırlık dosyası birlikte aranır. Yarım bir
    /// modelle özetlemeye kalkmak, kullanıcıya 6 GB indirtip hata göstermektir.
    static func isInstalled(_ model: LocalModel) -> Bool {
        let folder = directory(for: model)
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil) else { return false }
        var config = false, weights = false
        for case let url as URL in walker {
            if url.lastPathComponent == "config.json" { config = true }
            if url.pathExtension == "safetensors" { weights = true }
            if config && weights { return true }
        }
        return false
    }

    /// Diskte kapladığı yer — Ayarlar'daki depolama satırı.
    static func bytes(_ model: LocalModel) -> Int64 {
        let folder = directory(for: model)
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker { total += AudioArchive.bytes(at: url) }
        return total
    }

    @discardableResult
    static func delete(_ model: LocalModel) -> Bool {
        let folder = directory(for: model)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        else { return false }
        do {
            try FileManager.default.removeItem(at: folder)
            Log.info(.intelligence, "Yerel model silindi: \(model.id)")
            return true
        } catch {
            Log.error(.intelligence, "Yerel model silinemedi: \(model.id)", error)
            return false
        }
    }

    /// Bu makinede bu model çalışır mı? Ölçülen tepe belleğin üstüne pay
    /// bırakılır — sistem ve ora'nın kendisi de bellek kullanıyor.
    static func fits(_ model: LocalModel) -> Bool {
        Int64(ProcessInfo.processInfo.physicalMemory) >= model.peakMemoryBytes + 4_000_000_000
    }
}
