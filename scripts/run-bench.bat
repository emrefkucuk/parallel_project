@echo off
REM Phase 6+8 benchmark launcher with Java Flight Recorder enabled.
REM
REM Required positional argument:
REM   %1  payload-size-in-MB (e.g. 256 or 1024)
REM
REM Optional positional arguments:
REM   %2  thread-list (default: 1;2;4;8 — use semicolons on Windows CMD)
REM   %3  mode        (default: skewed; alternatives: uniform)
REM
REM Outputs:
REM   report\bench-<label>-<timestamp>.json     (BenchmarkRunner JSON)
REM   report\bench-<label>-<timestamp>.jfr      (Flight Recorder dump)
REM   report\bundle-<label>-<timestamp>\        (Phase 8 bundle:
REM       benchmark_full.csv, charts\*.png, notes.md)
REM
REM JFR is configured with the "profile" preset (Method Profiling sampling at
REM ~10ms, GC events, allocation profiling, JIT info, native method sampling).

setlocal enabledelayedexpansion

if "%~1"=="" (
  echo usage: run-bench.bat ^<size-mb^> [thread-list] [mode]
  echo   thread-list example: 1;2;4;8  (semicolons — commas break in CMD)
  exit /b 2
)

set SIZE_MB=%~1
set THREADS=%~2
if "%THREADS%"=="" set THREADS=1;2;4;8
set MODE=%~3
if "%MODE%"=="" set MODE=skewed

set TS=%date:~6,4%%date:~3,2%%date:~0,2%-%time:~0,2%%time:~3,2%%time:~6,2%
set TS=%TS: =0%
set LABEL=%SIZE_MB%m-%MODE%
set JFR=report\bench-%LABEL%-%TS%.jfr
set JSON=report\bench-%LABEL%-%TS%.json
set BUNDLE=report\bundle-%LABEL%-%TS%

if not exist report mkdir report
if not exist tmp     mkdir tmp

set SIGS=src\main\resources\signatures\main_subset.ndb
set PAYLOAD=tmp\smoke-%SIZE_MB%m-%MODE%.bin
set JAR=target\parallel-malware-scanner.jar

if not exist "%JAR%" (
  echo Shaded JAR not found at %JAR%. Run: mvn -q package -DskipTests
  exit /b 1
)

REM Build payload once (if missing) using the PayloadBuilder tool.
if not exist "%PAYLOAD%" (
  echo Building payload %PAYLOAD% ...
  java -cp "%JAR%" com.malwarescan.tools.PayloadBuilder ^
       --signatures "%SIGS%" ^
       --output     "%PAYLOAD%" ^
       --manifest   "tmp\smoke-%SIZE_MB%m-%MODE%.manifest.json" ^
       --size-mb    %SIZE_MB% ^
       --seeds      200 ^
       --rng        42 ^
       --mode       %MODE%
  if errorlevel 1 exit /b 1
)

echo Recording JFR to %JFR%
echo Writing JSON to  %JSON%
echo Writing bundle to %BUNDLE%

java -Xmx4g ^
     -XX:StartFlightRecording=duration=0s,settings=profile,filename=%JFR%,name=mw-scan ^
     -cp "%JAR%" ^
     com.malwarescan.benchmark.BenchmarkRunner ^
     --signatures "%SIGS%" ^
     --payload    "%PAYLOAD%" ^
     --parallelisms %THREADS% ^
     --warmup     2 ^
     --timed      5 ^
     --threshold-kb 1024 ^
     --label      %LABEL% ^
     --output     "%JSON%" ^
     --report-dir "%BUNDLE%"

if errorlevel 1 exit /b 1

echo.
echo Done.
echo   JSON  : %JSON%
echo   JFR   : %JFR%      (open with: jmc -open %JFR%)
echo   Bundle: %BUNDLE%   (CSV + charts + notes.md)
endlocal
