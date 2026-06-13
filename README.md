# Dynamic Two-Tiered Parallel Malware Scanner (CENG479)

This repository contains the project implementation prepared for the **CENG479 Parallel Programming** course.
The core operation is as follows:

- **Memory-mapping** the file to exclude disk I/O from measurements
- Performing parallel scanning on a **shared-memory** model over the CPU
- Using **ForkJoinPool work-stealing** to reduce thread starvation under irregular workloads
- Building a two-tier scanning pipeline:
  - **Tier 1 (fast filter)**: byte-level **rolling hash (Rabin-Karp)**
  - **Tier 2 (precise verification)**: exact matching via a from-scratch **Aho-Corasick DFA**

---

## Team

- 22118080039 — Emre Faruk Küçük
- 22118080058 — Yusuf Taha Sarıtiken

---

## Differences Between the Proposal and the Repository

Some points in the proposal required concrete decisions during implementation. Here is how they were resolved:

- **Wildcard signatures in ClamAV**
  - The proposal states that Tier 2 will use an *Aho-Corasick DFA*.
  - ClamAV `.ndb` files contain signatures with wildcards and metacharacters such as `?`, `*` and `{n-m}`.
  - **Decision**: The repository loads only **pure HEX** signatures that contain no wildcards.
    This keeps Tier 2 a true DFA, in direct alignment with the proposal.

- **Signature count ambiguity**
  - The proposal targets tens of thousands of signatures in the trie.
  - Correctness testing also requires injecting known signatures into the payload at known offsets.
  - **Decision**:
    - Trie / signature set: **50,000** signatures from `main_subset.ndb`
    - Synthetic payload: **200 seed** signatures selected from those 50,000 are injected at known offsets
    - This preserves the scale described in the proposal while enabling ground-truth validation.

- **Comparison requirement in the proposal**
  - The proposal requires benchmarking work-stealing against a **static, single-tier parallel** baseline in addition to the sequential baseline.
  - **Decision**: Two parallel modes are provided:
    - `dynamic`: `ForkJoinPool` work-stealing
    - `static`: fixed chunk distribution via `ExecutorService`

- **Proposal metric set**
  - The proposal specifies: speedup + efficiency + throughput (GB/s) + idle time + steal count + (optional) hardware counters.
  - **Decision**: Benchmark output is produced as a JSON/CSV + charts + `notes.md` bundle.
    Hardware counters (L1/L2 miss, stall cycles) require an external profiler; see `scripts/README.md`.

---

## Project Pipeline

### 1) Signature Loading (`.ndb`)

- Default signature file: `src/main/resources/signatures/main_subset.ndb`
- `SignatureLoader` parses `.ndb` lines and retains **only pure HEX** signatures.
- A `SignatureSet` is constructed containing:
  - A rolling-hash table for Tier 1
  - An Aho-Corasick DFA for Tier 2

### 2) Pre-loading the Payload (Isolating I/O from Measurement)

- The payload file is **memory-mapped** and scanned as **read-only**.
- During benchmarking, the performance timer starts only after mapping is complete.

### 3) Chunking and Overlap (the N-1 Rule)

- The payload is divided into logical chunks.
- If the longest signature length is **N**, each chunk reads **N-1** bytes of overlap beyond its own range.
- This ensures that any signature straddling a chunk boundary is captured by at least one thread without any inter-thread locking.

### 4) Tier 1 → Tier 2 Pipeline

- Each chunk is first scanned with the **rolling hash** for fast filtering.
- On a hash collision, the **Aho-Corasick** DFA is run at that offset for precise verification.

### 5) Parallelism (dynamic and static)

- `dynamic`: `ForkJoinPool` + work-stealing
- `static`: fixed distribution via `ExecutorService`

---

## Parallel Programming

This project uses parallel programming as a core feature in three main areas:

### 1) Dynamic Work Distribution: `ForkJoinPool` and Work-Stealing

The project uses Java's `ForkJoinPool`, which is built on the **work-stealing** algorithm, to balance the irregular workload distribution across threads. Because the distribution of malware signatures within a file and the frequency of Tier 2 transitions are unpredictable, some chunks take significantly longer to scan than others. To prevent resource waste (thread starvation) under this irregular workload, the payload is divided into many small tasks. When a thread finishes its own queue, it steals work from another thread's queue instead of sitting idle, maximizing CPU utilization. The `stealCount` metric collected during benchmarks allows the workload imbalance to be analyzed.

### 2) Static Parallel Baseline

To measure the performance gain targeted by the proposal, a comparison model using `ExecutorService` is also provided, with no dynamic load sharing between threads. In this model, the payload is divided into exactly as many equal-sized chunks as there are threads before scanning begins. A thread that finishes early becomes idle and does not assist others. This model was added specifically to compare the advantages of dynamic work distribution, particularly the effect of work-stealing on idle time.

### 3) Boundary Problem: Lock-Free Correctness via N-1 Overlap

To allow parallel worker threads to operate completely independently and eliminate the need for inter-thread locks, the data blocks are designed to overlap slightly. Taking the longest signature length in the dataset as N, each thread scans N-1 bytes of the neighboring region beyond its own chunk boundary. This prevents signatures that coincide exactly with chunk boundaries from being missed. After scanning, each match is filtered against whether it belongs to the thread's assigned range, preventing the same hit from being recorded more than once.

### 4) Shared Memory and the Lock-Free Approach

To maximize performance, the payload file is mapped into memory as read-only (`MappedByteBuffer`). This allows all threads to access the same data source concurrently without any locking overhead. Detected signature matches are collected into lock-free data structures during processing, avoiding slowdowns caused by concurrent access contention.

### 5) Parallel Performance Metrics

The benchmark produces the following metrics (CSV/JSON + charts):

- **Speedup**: S = T_s / T_p
- **Efficiency**: E = S / p
- **Throughput**: MB/s (convertible to GB/s in the report)
- **Idle time**: estimated time threads spent waiting
- **Steal count**: number of work-stealing operations

For hardware counters (L1/L2 miss, stall cycles) an external profiler is required: [`scripts/README.md`](scripts/README.md).

---

## Running with Docker

The project can be run on any system in a platform-independent manner via Docker, without requiring a local Java or Maven installation. The image includes GUI support via noVNC, so the application interface can be accessed through a browser.

### Prerequisites

Docker must be installed for your operating system:

- **Windows / macOS**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) must be installed and running in the background.
- **Linux**: Docker Engine and Docker Compose must be installed, and your current user should preferably be added to the `docker` group.

### Steps by Operating System

#### Windows

```cmd
docker compose up --build
```

#### macOS

```bash
docker compose up --build
```

#### Linux

```bash
docker compose up --build
```

### Accessing the GUI

Once the container is up and running, navigate to the following address in your web browser to access the application interface (regardless of operating system):

**http://localhost:8080/vnc.html**

---

## Requirements

- **JDK 17+**
- **Apache Maven 3.9+**
- (Optional) **JDK Mission Control (JMC)**: for opening `.jfr` files
  `jmc -open report\\bench-....jfr`
- (Optional) Profiler for hardware counters: Intel VTune / AMD uProf / Linux perf
  Details: [`scripts/README.md`](scripts/README.md)

---

## Build

```bat
mvn clean package
```

Output (runnable jar):

```bat
target\\parallel-malware-scanner.jar
```

---

## Running with the GUI

After building the project, start the interface with:

```bat
java -jar target\parallel-malware-scanner.jar
```

The application interface consists of two main sections:

- **Scan Module**: Allows users to select a signature database and a payload file to scan. Parameters such as the number of active threads and the chunk threshold can be configured before starting the analysis. Once the scan completes, a detailed list of matched malware signatures (hits) is displayed with offset, length, pattern index and name.
- **Performance Analysis (Benchmark) Module**: Tests scanning performance across different thread counts (e.g. 1, 2, 4, 8, 16). Provides a comparative analysis of dynamic (work-stealing) and static task distribution models, presents the resulting speedup and efficiency values as charts and allows the data to be exported.

---

## Command-Line (CLI) Analysis and Reporting

CLI scripts are available to eliminate GUI dependency for repeated performance measurements, particularly with large datasets.

**Standard Usage:**
To start the default analysis with a randomly generated 1024 MB test payload:

```bat
scripts\run-bench.bat 1024
```

**Custom Thread Configuration:**
To run the benchmark with a specific set of thread counts, pass the list as an argument:

```bat
scripts\run-bench.bat 1024 1;2;4;8;16 skewed
```

> [!WARNING]
> **Important Note for Windows**: The comma (`,`) character can break parameter parsing in batch scripts on Windows CMD. Always use **semicolons** (`;`) when specifying multiple thread counts.

**Generated Outputs and Reports:**
When the benchmark completes, comprehensive measurement data is compiled under the `report\` folder in the project root:

- `bench-<label>-<timestamp>.json` — Raw metrics file produced after the run.
- `bench-<label>-<timestamp>.jfr` — Detailed JFR (Java Flight Recorder) profile containing thread states, JIT compilation phases, memory usage and a method-level CPU profile.
- `bundle-<label>-<timestamp>\` — Consolidated report folder:
  - `benchmark_full.csv` — Summary table containing all comparative analysis data.
  - `charts\` — Generated visual charts for the evaluation metrics (throughput, speedup, efficiency, idle time).
  - `notes.md` — Automatically generated evaluation and commentary file based on the measurements.

---

## Code Structure

- `src/main/java/com/malwarescan/engine/` — `SignatureLoader`, `RollingHash`, `AhoCorasick`, `SignatureSet`
- `src/main/java/com/malwarescan/scanner/` — sequential / dynamic / static scan core
- `src/main/java/com/malwarescan/benchmark/` — benchmark runner + report bundle generation
- `src/main/java/com/malwarescan/gui/` — Scan / Benchmark tabs + charts
- `src/test/java/com/malwarescan/` — unit tests
