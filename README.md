# Dinamik İki Katmanlı Paralel Malware Tarayıcı (CENG479)

Bu repo, **CENG479 Parallel Programming** dersi için hazırladığımız proje implementasyonudur.
PDF’teki proposal başlığıyla uyumlu olarak hedefimiz şudur:

- Disk I/O’yu ölçümden çıkarmak için dosyayı **memory-map** etmek (`MappedByteBuffer`)
- CPU üzerinde **paylaşımlı bellek** modelinde paralel tarama yapmak
- Irregular iş yükünde thread starvation’ı azaltmak için **ForkJoinPool work-stealing** kullanmak
- İki aşamalı bir tarama pipeline’ı kurmak:
  - **Tier 1 (hızlı filtre)**: byte seviyesinde **rolling hash (Rabin–Karp)**
  - **Tier 2 (kesin doğrulama)**: sıfırdan **Aho–Corasick DFA** ile exact eşleşme

---

## Takım

- 22118080039 — Emre Faruk Küçük
- 22118080058 — Yusuf Taha Sarıtiken

---

## Proposal ↔ Plan ↔ Repo: Çelişkiler / Eksikler ve Nasıl Çözdük?

Proposal’daki bazı noktalar pratikte karar gerektiriyordu. Biz şu şekilde sabitledik:

- **ClamAV imzalarında wildcard konusu**  
  - Proposal Tier 2’de *Aho–Corasick DFA* diyor (exact multi-pattern).  
  - ClamAV `.ndb` içinde `?`, `*`, `{n-m}` gibi wildcard/metakarakterli imzalar var.  
  - **Karar**: Repo, yalnızca **wildcard içermeyen saf HEX** imzaları yüklüyor.  
    Böylece Tier 2 gerçekten DFA olarak kalıyor ve proposal ile birebir örtüşüyor.

- **“Tens of thousands signatures” vs “payload’a gömülen seed sayısı” karışıklığı**  
  - Proposal: trie’de **on binlerce** imza hedefliyor.  
  - Doğruluk testi için ayrıca payload’a bilinen offset’lere imza gömmek gerekiyor.  
  - **Karar (hibrit)**:
    - Trie / signature set: `main_subset.ndb` içinde **50.000** imza
    - Sentetik payload: bu imzalardan seçilmiş **200 seed** imza bilinen offset’lere enjekte ediliyor
    - Böylece hem proposal’daki ölçek korunuyor hem de ground-truth doğrulama yapılabiliyor.

- **PDF §6’daki karşılaştırma zorunluluğu (dynamic vs static)**  
  - Proposal sadece sequential baseline istemiyor; ayrıca **static, single-tier parallel** ile
    **work-stealing** karşılaştırmasını istiyor.  
  - **Karar**: İki paralel mod var:
    - `dynamic`: `ForkJoinPool` work-stealing
    - `static`: `ExecutorService` ile sabit chunk dağıtımı (steal yok)

- **PDF §6 metrik seti**  
  - Proposal: speedup + efficiency + throughput (GB/s) + idle time + steal count + (opsiyonel) HW counters.  
  - **Karar**: Benchmark çıktısı JSON/CSV + grafikler + `notes.md` olarak bundle içinde üretiliyor.
    HW counter kısmı için (L1/L2 miss, stall cycles) harici profiler gerekiyor; bkz. `scripts/README.md`.

---

## Proje Şu An Ne Yapıyor? (Adım adım)

### 1) İmza yükleme (`.ndb`)

- Varsayılan imza dosyası: `src/main/resources/signatures/main_subset.ndb`
- `SignatureLoader`, `.ndb` satırlarını parse eder ve **sadece saf HEX** imzaları alır.
- `SignatureSet` oluşturulur:
  - Tier 1 için rolling-hash tablosu (collision adayları)
  - Tier 2 için Aho–Corasick DFA (`goto`/`failure`/`output`)

### 2) Payload’ı pre-load etmek (I/O’yu ölçümden ayırmak)

- Payload dosyası **memory-map** edilir (`MappedByteBuffer`) ve **read-only** taranır.
- Benchmark sırasında süre ölçümü, mapping tamamlandıktan sonra başlar (proposal’daki “I/O’yu dışarıda tutma” şartı).

### 3) Chunking + overlap (N-1 kuralı)

- Payload mantıksal chunk’lara bölünür.
- **En uzun imza uzunluğu \(N\)** ise her chunk, kendi aralığına ek olarak **\(N-1\)** byte overlap okur.
- Böylece bir imza chunk sınırını geçse bile en az bir thread tarafından yakalanır; inter-thread lock gerekmez.

### 4) Tier 1 → Tier 2 pipeline

- Her chunk üzerinde önce **rolling hash** ile hızlı tarama yapılır.
- Hash collision olursa o offset’te **Aho–Corasick** ile kesin doğrulama yapılır.

### 5) Paralellik (dynamic ve static)

- `dynamic`: `ForkJoinPool` + work-stealing (irregular yükte daha dengeli CPU kullanımı hedefler)
- `static`: sabit dağıtım (steal yok), proposal’daki karşılaştırma için baseline

---

## Paralel Programlama İçeren Kısımlar (Ne? Nasıl çalışıyor?)

Bu projede paralel programlama 3 ana yerde “çekirdek özellik” olarak kullanılıyor:

### 1) Dinamik iş dağıtımı: `ForkJoinPool` + Work-Stealing (dynamic mod)

- **Ne?** Java’nın work-stealing kullanan fork/join framework’ü.
- **Neden?** Malware yoğunluğu (ve Tier 2’ye düşme sıklığı) chunk’lar arasında düzensiz → sabit dağıtımda bazı thread’ler boşta kalabilir.
- **Nasıl?**
  - Payload çok sayıda küçük işe (chunk task) bölünür.
  - Her worker thread kendi deque’sinden iş alır.
  - Bir thread işi bitirirse, diğer thread’in kuyruğundan **iş “çalabilir”** (steal).
  - Benchmark’ta `stealCount` ölçülür; proposal’daki hipotez (starvation azalır) bu veriyle tartışılır.

### 2) Statik paralel baseline (static mod)

- **Ne?** Work-stealing olmadan, işi baştan sabit paylaştıran paralel tarama.
- **Neden?** PDF §6 “dynamic work-stealing”i **static, single-tier parallel** ile karşılaştırmayı istiyor.
- **Nasıl?**
  - Payload N parçaya bölünür ve her parçayı bir thread tarar.
  - Thread işini bitirirse boşta bekler; başka thread’in işini devralmaz.
  - “Idle time” bu yüzden dynamic’e kıyasla artabilir.

### 3) Sınır (boundary) problemi: N-1 overlap ile lock’suz doğruluk

- **Ne?** Bir signature chunk sınırını geçerse kaçmaması için overlap.
- **Neden?** Chunk’lar bağımsız taranmalı; thread’ler arası koordinasyon/lock istemiyoruz.
- **Nasıl?**
  - En uzun signature uzunluğu \(N\) ise her chunk, komşu bölgeye doğru **\(N-1\)** byte daha okur.
  - Sonuç yazarken “bu hit benim esas aralığımda mı?” filtresi uygulanır → duplicate’ler engellenir.

### 4) Paylaşımlı bellek ve lock-free yaklaşım

- **Payload erişimi**: `MappedByteBuffer` **read-only** → aynı veriye çoklu thread kilitsiz bakar.
- **Sonuç toplama**: Hit’ler lock-free veri yapısına yazılır (pratikte çok az contention; amaç scan kernel’ini lock’lardan arındırmak).

### 5) Paralel performans metrikleri (proposal §6)

Benchmark şu metrikleri üretir (CSV/JSON + grafik):

- **Speedup**: \(S = T_s / T_p\)
- **Efficiency**: \(E = S / p\)
- **Throughput**: MB/s (raporda GB/s’ye çevrilebilir)
- **Idle time**: thread’lerin boşta kaldığı süre tahmini
- **Steal count**: work-stealing operasyon sayısı

Donanım sayaçları (L1/L2 miss, stall cycles) için harici profiler gerekir: [`scripts/README.md`](scripts/README.md).

---

## Gereksinimler (Ne kurmalıyım?)

- **JDK 17+** (bizde JDK 24 ile test edildi)
- **Apache Maven 3.9+**
- (Opsiyonel) **JDK Mission Control (JMC)**: `.jfr` dosyasını açmak için  
  `jmc -open report\\bench-....jfr`
- (Opsiyonel) HW counters için profiler: Intel VTune / AMD uProf / Linux perf  
  Detay: [`scripts/README.md`](scripts/README.md)

---

## Build

```bat
mvn clean package
```

Çıktı (runnable jar):

```bat
target\\parallel-malware-scanner.jar
```

---

## Çalıştırma (GUI)

```bat
java -jar target\\parallel-malware-scanner.jar
```

GUI’de iki sekme var:

- **Scan**: (imza dosyası + payload seç) → thread sayısı + chunk threshold ayarla → tarat → hit listesini gör
- **Benchmark**: 1/2/4/8/16 thread sweep + dynamic/static karşılaştırması → grafikler + export

---

## Çalıştırma (CLI benchmark + rapor bundle)

Windows’ta (CMD) hızlı kullanım:

```bat
scripts\\run-bench.bat 1024
```

Thread listesi vermek istersen:

```bat
scripts\\run-bench.bat 1024 1;2;4;8;16 skewed
```

> Önemli: **Windows CMD’de virgül yerine noktalı virgül (`;`) kullan**.  
> (Virgül, batch argümanlarını bölebiliyor.)

Üretilen çıktılar (`report\\` altında):

- `bench-<label>-<ts>.json` — ham benchmark sonuçları
- `bench-<label>-<ts>.jfr` — JFR dump (CPU profile/threads/JIT/allocations)
- `bundle-<label>-<ts>\\` — rapor bundle:
  - `benchmark_full.csv`
  - `charts\\throughput.png`, `speedup.png`, `efficiency.png`, `idle.png`
  - `notes.md` (otomatik özet/yorum)

---

## Demo Akışı (10 dakika)

Takım arkadaşın projeyi hızlıca “çalışıyor mu / ne üretiyor” diye görmek isterse:

### 1) Build (1 dk)

```bat
mvn clean package
```

### 2) Kısa CLI benchmark (3–6 dk)

64 MB ile hızlı smoke:

```bat
scripts\\run-bench.bat 64
```

1 GB (daha anlamlı grafikler, daha uzun):

```bat
scripts\\run-bench.bat 1024
```

> İstersen thread listesi: `1;2;4;8;16` (CMD’de `;`).

### 3) Bundle çıktısına bak (1 dk)

`report\\bundle-...\\` altında şunlar oluşur:

- `benchmark_full.csv` (tüm metrik tablo)
- `charts\\*.png` (throughput/speedup/efficiency/idle)
- `notes.md` (otomatik kısa yorum)

### 4) JFR aç (opsiyonel, 2 dk)

```bat
jmc -open report\\bench-....jfr
```

JMC’de özellikle şu view’lar faydalı:

- **Method Profiling**: scan kernel hot spot’ları (rolling hash / AC scan loop)
- **Threads**: static vs dynamic idle farkını görmek

### 5) GUI demo (opsiyonel, 1–2 dk)

```bat
java -jar target\\parallel-malware-scanner.jar
```

- Benchmark sekmesinden suite çalıştır → grafiklerin canlı dolduğunu göster

---

## Kod Yapısı (kısa)

- `src/main/java/com/malwarescan/engine/` — `SignatureLoader`, `RollingHash`, `AhoCorasick`, `SignatureSet`
- `src/main/java/com/malwarescan/scanner/` — sequential/dynamic/static tarama çekirdeği
- `src/main/java/com/malwarescan/benchmark/` — benchmark runner + report bundle üretimi
- `src/main/java/com/malwarescan/gui/` — Scan/Benchmark tab’ları + chart’lar
- `src/test/java/com/malwarescan/` — unit testler
