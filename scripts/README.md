# Benchmark and profiling workflow

This directory contains helper scripts to run the Phase 6 benchmark
(`BenchmarkRunner`) under Java Flight Recorder (JFR) and to optionally attach
an external CPU hardware counter profiler.

## Quick start (Windows)

```bat
mvn -q clean package
scripts\run-bench.bat 1024 1;2;4;8 skewed
```

This produces:

- `report\bench-<label>-<timestamp>.json` — `BenchmarkRunner` JSON output
  (mean / std-dev / throughput / idle / steal count per scanner+parallelism).
- `report\bench-<label>-<timestamp>.jfr` — Flight Recorder dump.

The first argument is the payload size in MB. The optional second is a
comma-separated thread list (default `1,2,4,8`). The third selects the
synthetic payload mode: `skewed` (seeds clustered in the middle 20 %) or
`uniform`.

## Inspecting the JFR file

Open the recording with JDK Mission Control:

```bat
jmc -open report\bench-1024m-skewed-<timestamp>.jfr
```

JMC views useful for this project:

- **Method Profiling** — sampled CPU hot spots; expect the AC scan loop in
  `com.malwarescan.engine.AhoCorasick.scan` and the rolling-hash loop in
  `com.malwarescan.scanner.ScanCore.scanChunk` to dominate.
- **Threads** — per-thread wall/CPU time, useful for visualizing how much
  each worker actually executes vs sits idle in the static baseline.
- **Lock Instances** — should be empty; the parallel scanner is lock-free
  apart from the lock-free `ConcurrentLinkedQueue` in `ConcurrentMatchSink`.

## Hardware performance counters

JFR does not expose L1/L2 cache miss rates or CPU pipeline stall cycles
directly. The PDF §6 metrics that depend on hardware counters require an
external profiler:

### Intel CPUs — Intel VTune Profiler (free)

1. Install Intel oneAPI Base Toolkit; VTune Profiler ships with it.
2. Launch VTune, *New Project → Custom Analysis*.
3. *Application* = `java`, *Application parameters* = the same arguments
   that `run-bench.bat` passes (see the `java -cp ...` line in the script
   to copy the exact command). Set the working directory to the project
   root.
4. Choose the **Microarchitecture Exploration** analysis type — this
   collects L1/L2 cache miss rates and CPI / pipeline stall cycles.
5. Run the analysis. The results are grouped per module/function; filter
   to `com.malwarescan.*` to focus on the scan kernel.

### AMD CPUs — AMD uProf (free)

The equivalent analysis on AMD hardware is *uProf → Power Profiling +
Time-based Profiling*. uProf's "Cache" group also reports L1/L2 miss
ratios for the JVM process.

### Linux only — `perf stat` (one-liner)

If running on Linux with `linux-tools` installed:

```bash
perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses java -cp target/classes \
   com.malwarescan.benchmark.BenchmarkRunner --signatures ... --payload ...
```

This reports the same counters that VTune/uProf expose. async-profiler
(`-e cpu,cache-misses,cache-references`) can be attached in parallel to
sample hot stacks correlated with hardware events.

## Reproducibility checklist

- Same JVM version across runs (`scripts\run-bench.bat` prints the version
  used in the metadata block of the JSON output).
- Pin process priority to *Realtime* in the Task Manager *Details* tab to
  reduce OS scheduling noise.
- Disable Windows Defender real-time scanning on the `tmp\` and `target\`
  directories for the duration of the run; otherwise the AV will scan the
  same MappedByteBuffer pages we are scanning and skew throughput.
- Run on AC power; laptops downclock aggressively under battery.
