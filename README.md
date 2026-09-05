# autoInSAR: Automated Sentinel-1 InSAR Dual-Mode Processing Pipeline

[![Status](https://img.shields.io/badge/Status-Active-brightgreen)](https://github.com/limingjia92/autoInSAR)
[![License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**autoInSAR** is a high-level automation wrapper for the **ISCE2** Sentinel-1 InSAR workflow. It supports both conventional two-scene D-InSAR processing and large Sentinel-1 SLC stacks prepared for time-series analysis with **StaMPS-HPC**.

The pipeline automates data discovery, download, orbit preparation, DEM preparation, ISCE2 configuration, processing, post-processing, and optional cleanup. In Stack mode, autoInSAR v2 also provides hardware-aware parallel scheduling, GPU-aware execution, per-task progress/logging, and automatic restart from validated stage checkpoints.

---

## 1. Processing Modes

The processing track is selected with `--mode`.

### `pair` — D-InSAR mode

Designed for co-seismic or other single-pair deformation analysis. autoInSAR wraps `topsApp.py` and produces:

- unwrapped phase;
- LOS displacement;
- coherence;
- range/azimuth pixel offsets;
- look-vector components;
- geocoded grids and 2-D plots.

### `stack` — time-series preparation mode

Designed as an upstream data-preparation workflow for [StaMPS-HPC](https://github.com/limingjia92/StaMPS-HPC). autoInSAR wraps `stackSentinel.py` to:

- prepare a co-registered Sentinel-1 SLC stack;
- execute the generated `run_*` stages in dependency order;
- dynamically parallelize independent tasks inside each stage;
- use GPU-aware scheduling for `geo2rdr` stages;
- maintain stage completion markers and per-task logs;
- generate baseline-network plots and StaMPS-HPC command suggestions.

> Stack processing must use a single relative orbit. If more than one orbit is found during search, autoInSAR stops and asks you to rerun with an explicit `--rel_orbit`.

---

## 2. Pipeline Overview

The pipeline contains eight named steps:

| Step | `--step` value | Pair mode | Stack mode |
| --- | --- | --- | --- |
| 1 | `search` | Search a two-date/event acquisition set | Search a time-series acquisition set |
| 2 | `download` | Download Sentinel-1 SLC ZIP files | Download Sentinel-1 SLC ZIP files |
| 3 | `orbit` | Download POEORB/RESORB orbit files | Download POEORB/RESORB orbit files |
| 4 | `dem` | Download and stitch SRTMGL1 DEM | Download and stitch SRTMGL1 DEM |
| 5 | `config` | Generate `reference.xml`, `secondary.xml`, `tops.xml` | Run `stackSentinel.py` and generate serial-form `run_*`/config files |
| 6 | `process` | Run `topsApp.py` | Run all Stack stages with AutoInSAR's dynamic scheduler |
| 7 | `post` | Extract displacement/offset products and plots | Analyze baselines and generate PS/SBAS plots/commands |
| 8 | `clean` | Remove bulky source/intermediate data while retaining selected results | Remove source/intermediate directories while preserving `process/merged/` |

### What does `--step all` do?

`all` is the default and executes:

```text
search -> download -> orbit -> dem -> config -> process -> post
```

**`clean` is intentionally NOT included in `all`.** Cleanup must always be requested explicitly:

```bash
autoInSAR.py --mode stack --step clean
```

This prevents successful source/intermediate data from being deleted automatically at the end of a long run.

---

## 3. Prerequisites

- **Linux** — recommended/expected for the ISCE2 workflow.
- **ISCE2 v2.6+** — `topsApp.py`, `stackSentinel.py`, and `dem.py` must be available in `PATH`.
- **wget** — used for SLC/orbit/DEM downloading.
- **Python packages**:

```bash
pip install numpy matplotlib requests gdal
```

- **Sentinel-1 data credentials** — configure ASF/NASA Earthdata or Copernicus Data Space credentials as described below.
- **NVIDIA/CUDA support** — the current ISCE configuration requests GPU processing (`useGPU`). Ensure that your ISCE2 installation and NVIDIA environment support the GPU-enabled stages you intend to run.

### ASF / NASA Earthdata credentials

Create or edit `~/.netrc`:

```bash
nano ~/.netrc
```

Add:

```text
machine urs.earthdata.nasa.gov login YOUR_EARTHDATA_USERNAME password YOUR_EARTHDATA_PASSWORD
```

Restrict permissions:

```bash
chmod 600 ~/.netrc
```

### Copernicus Data Space Ecosystem credentials

Create or edit `~/.cdse_credentials`:

```bash
nano ~/.cdse_credentials
```

Add:

```text
username=YOUR_COPERNICUS_USERNAME
password=YOUR_COPERNICUS_PASSWORD
```

Restrict permissions:

```bash
chmod 600 ~/.cdse_credentials
```

Do not commit real credentials to GitHub.

---

## 4. Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/limingjia92/autoInSAR.git
cd autoInSAR
chmod 755 autoInSAR.py
```

Optionally add the repository directory to `PATH`:

```bash
export PATH="/path/to/autoInSAR:$PATH"
```

Add the line above to `~/.bashrc` or `~/.zshrc` for persistent use, then reload the shell:

```bash
source ~/.bashrc
```

After that, `autoInSAR.py` can be called from the working directory of an InSAR project.

---

## 5. Quick Start

### 5.1 Pair mode — event search

Search approximately ±12 days around an event date and process the resulting pair:

```bash
autoInSAR.py \
    --mode pair \
    --lon 87.378 --lat 28.604 \
    --event_date 20250107 \
    --platform S1A \
	--rel_orbit 121S
```

### 5.2 Pair mode — manual dates

```bash
autoInSAR.py \
    --mode pair \
    --lon 87.378 --lat 28.604 \
    --reference_date 20250101 \
    --secondary_date 20250113 \
	--rel_orbit 121
```

### 5.3 Stack mode — automatic parallel scheduling

`--num_proc 0` is the default and enables hardware-aware automatic worker selection:

```bash
autoInSAR.py \
    --mode stack \
    --lon 40.7 --lat 13.6 \
    --start_date 20200101 \
    --end_date 20231231 \
    --rel_orbit 14 \
    --num_proc 0
```

### 5.4 Stack mode — manually override the general worker ceiling

For example, request up to six concurrent tasks for the scalable Stack stages:

```bash
autoInSAR.py \
    --mode stack \
    --lon 40.7 --lat 13.6 \
    --start_date 20200101 \
    --end_date 20231231 \
    --rel_orbit 14 \
    --num_proc 6
```

A positive `--num_proc` overrides the conservative automatic CPU/storage recommendation for the general scalable stages, but remains bounded by actual available CPU and memory.

### 5.5 Copernicus data source

```bash
autoInSAR.py \
    --data_source copernicus \
    --mode stack \
    --lon -67.9 --lat 10.5 \
    --start_date 20260610 \
    --end_date 20260627 \
    --rel_orbit 106 \
    --platform S1D
```

### 5.6 Separate search coverage from processing ROI

Use a wider area for SLC discovery while processing a smaller ROI:

```bash
autoInSAR.py \
    --mode pair \
    --lon 40.7 --lat 13.6 \
    --event_date 20251117 \
    --search_dlonlat 0.5 \
    --roi_dlonlat 0.2
```

### 5.7 Full-extent processing

Set `--roi_dlonlat 0` to omit an explicit ISCE ROI and use the full available overlap:

```bash
autoInSAR.py \
    --mode pair \
    --lon 40.7 --lat 13.6 \
    --event_date 20251117 \
    --search_dlonlat 0.5 \
    --roi_dlonlat 0
```

---

## 6. Running Individual Steps

Use `--step` to run one pipeline stage at a time. Valid values are:

```text
search  download  orbit  dem  config  process  post  clean  all
```

> **Important:** except for `clean`, the current command-line validation still expects the normal spatial and mode-specific date arguments even when only a later step is requested. This keeps execution context explicit and avoids accidentally operating on the wrong project.

### Typical Stack workflow executed step-by-step

```bash
# Step 1: search
autoInSAR.py --mode stack --step search \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Step 2: download
autoInSAR.py --mode stack --step download \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Step 3: orbit
autoInSAR.py --mode stack --step orbit \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Step 4: DEM
autoInSAR.py --mode stack --step dem \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Step 5: generate stackSentinel configs/run files
autoInSAR.py --mode stack --step config \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Step 6: execute the Stack scheduler; here the general worker ceiling is 6
autoInSAR.py --mode stack --step process \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157 \
    --num_proc 6

# Step 7: baseline analysis / StaMPS-HPC command generation
autoInSAR.py --mode stack --step post \
    --lon 110.0 --lat 19.2 \
    --start_date 20180101 --end_date 20241231 \
    --rel_orbit 157

# Optional Step 8: cleanup
autoInSAR.py --mode stack --step clean
```

### Re-running `--step process`

Stack mode is checkpoint-aware. If valid completion markers already exist, rerunning the same command automatically skips completed stages and resumes from the first incomplete, interrupted, failed, or invalidated stage.

You do **not** need a `--start_run` or `--stop_run` argument.

---

## 7. Stack-Mode Scheduler and `--num_proc`

### 7.1 Why Step 5 generates serial-form run files

In Stack mode, Step 5 deliberately calls `stackSentinel.py` with:

```text
--num_proc 1 --num_proc4topo 1
```

This does **not** mean that Step 6 is serial. It keeps each generated `run_*` file in a clean one-command-per-task form so that autoInSAR can perform its own dynamic scheduling, progress reporting, logging, GPU assignment, and restart handling.

### 7.2 Automatic mode: `--num_proc 0`

When `--num_proc 0` is used, autoInSAR inspects:

- CPU affinity / available CPU threads;
- available memory and cgroup memory limits;
- filesystem and storage type;
- visible NVIDIA GPUs.

The automatic general worker ceiling is conservatively derived from CPU, memory, and storage recommendations. Current storage-aware defaults are approximately:

| Storage class | Automatic storage cap |
| --- | ---: |
| Network filesystem (`nfs`, `cifs`, etc.) | 2 |
| NTFS/exFAT/FUSE-style conservative local filesystem | 2 |
| HDD | 4 |
| Unknown local storage | 4 |
| SSD | 8 |
| NVMe | 12 |
| Parallel filesystem (e.g. Lustre/GPFS/BeeGFS/CephFS) | 12 |

The final automatic value can be lower if CPU or available memory is more restrictive.

### 7.3 Manual mode: `--num_proc N`

A positive value requests a user-selected maximum for the general scalable stages:

```bash
--num_proc 6
```

or:

```bash
--num_proc 8
```

Manual mode intentionally allows advanced users to exceed the conservative storage-aware recommendation. The requested value is still reduced if it exceeds the actual available CPU or the memory safety ceiling.

> `--num_proc` means **concurrent ISCE tasks**, not CPU cores. A single ISCE task may itself use multiple CPU threads. Higher values therefore do not always reduce wall-clock time; monitor CPU load and disk I/O when tuning this option.

### 7.4 Stage-specific worker policy

The general worker ceiling is **not** applied blindly to every ISCE stage. Current Stack scheduling policy is:

| Run stage | Scheduling policy |
| --- | --- |
| `run_01` | 1 worker |
| `run_02` | conservative I/O-aware limit (typically 2 on HDD/network/unknown storage, up to 4 on faster local storage) |
| `run_03` | general `--num_proc` ceiling |
| `run_04` | 1 worker |
| `run_05` | GPU-aware; limited by visible GPU count and global ceiling |
| `run_06` | general `--num_proc` ceiling |
| `run_07` | general `--num_proc` ceiling |
| `run_08` | 1 worker |
| `run_09` | GPU-aware; limited by visible GPU count and global ceiling |
| `run_10` | general `--num_proc` ceiling |
| `run_11` | 1 worker |
| `run_12` | dedicated I/O-aware limit (typically 2 on HDD/unknown storage) |
| `run_13` | general `--num_proc` ceiling |

For a single visible GPU, `run_05` and `run_09` normally run with one worker. Terminal output such as:

```text
[START 3/202] config_fullBurst_geo2rdr_20180128 | GPU=0
```

means that the task is assigned to **GPU device 0**; it does not mean 0% GPU utilization.

### 7.5 Dynamic task scheduling

Within one `run_*` stage, independent tasks are scheduled dynamically. For example, with six workers, autoInSAR starts six tasks and immediately launches the next pending task whenever any worker finishes. It does not wait for a fixed batch of six tasks to finish together.

Different `run_*` stages remain strictly sequential because downstream ISCE stages depend on upstream outputs.

---

## 8. Stack Progress, Logs, and Automatic Restart

### 8.1 Terminal progress

For multi-task stages, autoInSAR reports task start/completion, elapsed time, percentage, ETA, and active tasks, for example:

```text
[Run 10/13] START run_10_fullBurst_resample
[*] Stage tasks      : 202
[*] Parallel workers : 6

    [START 1/202] config_fullBurst_resample_20180104
    [DONE 1/202 |   0.50%] config_fullBurst_resample_20180104 | task=0:14:28 | ETA=...
```

### 8.2 Per-task logs

Each Stack task receives its own log file under:

```text
process/logs/stack_runs/<run_name>/
```

For example:

```text
process/logs/stack_runs/run_10_fullBurst_resample/
    0001_config_fullBurst_resample_20180104.log
    0002_config_fullBurst_resample_20180116.log
    ...
```

For GPU stages, the log header also records `CUDA_VISIBLE_DEVICES`.

### 8.3 Stage state markers

Stack Step 6 records stage state under:

```text
process/autoinsar_state/
```

Possible markers include:

```text
run_01.done
run_06.running
run_10.failed
```

A `.done` marker contains metadata such as the run name, task count, worker count, hostname, timing information, and a fingerprint of the corresponding run/config files.

When `--step process` is executed again:

1. valid `.done` stages are skipped automatically;
2. an interrupted/failed/stale stage is recomputed from the beginning of that stage;
3. all downstream stages are then recomputed to preserve dependency consistency.

This makes long Stack processing restartable without introducing additional run-number command-line arguments.

---

## 9. Arguments

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `--mode` | String | No | `pair` or `stack`. Default: `pair`. |
| `--data_source` | String | No | `asf` or `copernicus`. Default: `asf`. |
| `--lon` | Float | Yes* | Center longitude of the study area. |
| `--lat` | Float | Yes* | Center latitude of the study area. |
| `--event_date` | String | Pair only | Event date (`YYYYMMDD`); searches approximately ±12 days. |
| `--reference_date` | String | Pair only | Manual reference date (`YYYYMMDD`). |
| `--secondary_date` | String | Pair only | Manual secondary date (`YYYYMMDD`). |
| `--start_date` | String | Stack only | Stack start date (`YYYYMMDD`). |
| `--end_date` | String | Stack only | Stack end date (`YYYYMMDD`). |
| `--num_proc` | Int | No | **Stack mode.** General concurrent-task ceiling for `run_03/06/07/10/13`. `0` = automatic resource-aware selection (default); positive value = manual override within actual CPU/memory safety limits. |
| `--platform` | String | No | Sentinel-1 platform. Accepted values: `Sentinel-1`, `Sentinel-1A/B/C/D`, `S1`, `S1A/B/C/D`. Default: `Sentinel-1`. |
| `--rel_orbit` | Int | No** | Relative orbit number used to filter acquisitions. Strongly recommended for Stack mode. |
| `--search_dlonlat` | Float | No | Search half-width in degrees around `--lon/--lat`. Default: `0.2`. |
| `--roi_dlonlat` | Float | No | Processing/post-processing ROI half-width in degrees. Defaults to `--search_dlonlat`. Use `0` to disable ROI clipping. |
| `--dlonlat` | Float | No | Deprecated compatibility alias. Prefer `--search_dlonlat` and `--roi_dlonlat`. |
| `--zip_check_backend` | String | No | ZIP validation backend: `auto`, `python`, or `zipinfo`. Default: `auto`. |
| `--step` | String | No | One of `search`, `download`, `orbit`, `dem`, `config`, `process`, `post`, `clean`, `all`. Default: `all`. |

\* `--lon` and `--lat` are not required for `--step clean`; other steps currently use normal mode validation.

Pair mode requires either `--event_date` **or** both `--reference_date` and `--secondary_date`.

Stack mode requires both `--start_date` and `--end_date` for normal execution. If multiple relative orbits overlap the search area, an explicit `--rel_orbit` is required before processing can continue.

### Search buffer vs. processing ROI

- `--search_dlonlat` controls which SLC scenes are discovered by ASF/Copernicus search.
- `--roi_dlonlat` controls the ISCE processing ROI and Pair-mode post-processing crop.
- If `--roi_dlonlat` is omitted, it follows `--search_dlonlat`.
- If `--roi_dlonlat 0` is used, the Pair ROI entry and Stack `-b` option are omitted, so the full available overlap is processed.

---

## 10. Output Structure

### 10.1 Stack mode — before cleanup

During/after Stack processing, the working tree contains ISCE inputs, intermediate products, scheduler metadata, and final merged products. Important directories include:

```text
process/
├── autoinsar_state/            # .done/.running/.failed stage markers
├── configs/                    # stackSentinel task configuration files
├── run_files/                  # run_* stage files generated by stackSentinel.py
├── logs/
│   └── stack_runs/             # per-task AutoInSAR logs
├── reference/
├── secondarys/
├── coreg_secondarys/
├── baselines/
└── merged/
    ├── SLC/                    # coregistered SLC stack
    ├── baselines/              # baseline grids/products
    └── geom_reference/         # geometry products

results/
├── stack_baselines_PS_*.png
├── stack_baselines_SBAS_*.png
└── stamps_hpc_commands.txt
```

The exact intermediate directories are controlled by the ISCE2 `stackSentinel.py` workflow and may vary with ISCE2 version/configuration.

### 10.2 Stack mode — after explicit cleanup

`--step clean` removes the top-level `SLC/`, `DEM/`, `orbits/`, and `AUX/` directories and removes Stack intermediate subdirectories under `process/`, while preserving `process/merged/` and the `results/` directory:

```text
process/
└── merged/
    ├── SLC/
    ├── baselines/
    └── geom_reference/

results/
├── stack_baselines_PS_*.png
├── stack_baselines_SBAS_*.png
└── stamps_hpc_commands.txt
```

Because `autoinsar_state/`, `run_files/`, `configs/`, and task-log directories are intermediate directories, do not run cleanup until you are satisfied that Stack processing and validation are complete.

### 10.3 Pair mode outputs

```text
process/
├── tops.xml
└── merged/

results/
├── los_disp.grd               # LOS displacement (m)
├── coherence.grd              # interferometric coherence
├── wrap_phase.grd             # wrapped phase
├── vec_E.grd                  # east component of LOS unit vector
├── vec_N.grd                  # north component of LOS unit vector
├── vec_U.grd                  # vertical component of LOS unit vector
├── offset_range.grd           # range-direction pixel offset (m), when available
├── offset_azimuth.grd         # azimuth-direction pixel offset (m), when available
├── snr.grd                    # offset SNR, when available
└── plot_asc_XX/ or plot_des_XX/
```

Depending on GDAL build capabilities, `.grd` output may fall back to GeoTIFF.

---

## 11. Practical Parallel-Processing Notes

For Stack mode, start with automatic scheduling unless you already know the server/storage behavior:

```bash
--num_proc 0
```

For a CPU-rich server with a single HDD, the automatic recommendation is typically conservative (often 4 general tasks). Advanced users can test values such as:

```bash
--num_proc 6
```

or:

```bash
--num_proc 8
```

when the machine has sufficient CPU and memory. Increasing `--num_proc` is useful only while total throughput improves. For performance tuning, monitor:

```bash
top
iostat -xz 2
nvidia-smi
```

Useful interpretation:

- high CPU utilization with low I/O wait can indicate that a larger task pool is still productive;
- high disk latency/I/O wait may indicate excessive concurrent resampling/merge activity;
- `run_05`/`run_09` are GPU-aware stages;
- `run_06`/`run_10` can be both CPU- and I/O-intensive;
- `run_12` intentionally uses a more conservative I/O-aware limit.

---

## 12. License

This project is licensed under the **MIT License**. See [`LICENSE`](LICENSE) for details.

Author: **Mingjia Li**  
Copyright (c) 2026 Mingjia Li
