# autoInSAR: Automated Sentinel-1 InSAR Dual-Mode Processing Pipeline

[![Status](https://img.shields.io/badge/Status-Active-brightgreen)](https://github.com/limingjia92/StaMPS-HPC)
[![License](https://img.shields.io/badge/License-GPL--v3.0-blue)](LICENSE)

-----------------------------------------------------------------------

**autoInSAR** is a fully automated, dual-track InSAR processing pipeline designed for **Sentinel-1** data. 

It serves as a high-level wrapper around the **ISCE2** (InSAR Scientific Computing Environment) software ecosystem, automating the entire lifecycle of interferometry—from data search and download to interferogram generation, baseline network analysis, and result visualization.

## 1. Dual-Mode Architecture

The pipeline operates in two distinct modes controlled by the `--mode` argument:

* **[Mode A] `pair` (D-InSAR Mode):** Designed for rapid co-seismic or single-pair deformation analysis. Wraps `topsApp.py` to generate final unwrapped phase, LOS displacement, and 2D publication-ready plots.
* **[Mode B] `stack` (Time-Series Mode):** Designed as the **official upstream data feeder for the [StaMPS-HPC](https://github.com/limingjia92/StaMPS-HPC) framework**. Wraps `stackSentinel.py` to prepare massive, perfectly coregistered SLC stacks, evaluates the spatiotemporal baseline network, and auto-recommends StaMPS processing parameters.

## 2. Features

The pipeline automates the following 8 steps dynamically based on the selected mode:

1.  **Search**: Auto-query SLC images from the ASF API. Supports event-based search (±12 days), manual pairs, or multi-year time-series stacks.
2.  **Download**: Sequential downloading of SLC data with ZIP integrity verification and auto-resume.
3.  **Orbit**: Auto-fetch Precision (POEORB) or Restituted (RESORB) orbit files with robust time-window matching.
4.  **DEM**: Auto-download and stitch SRTMGL1 DEM tiles covering the region of interest.
5.  **Config**: Auto-generation of ISCE XML configs (`tops.xml`) OR sequential execution scripts (`run_01` to `run_13` for stack mode).
6.  **Process**: Execution of the standard `topsApp.py` workflow OR safe, sequential execution of the stack scripts.
7.  **Post-Processing**: 
    * *(Pair)*: GDAL extraction, E/N/U decomposition, and Matplotlib 2D visualization.
    * *(Stack)*: Spatiotemporal baseline network plotting and automated PS/SBAS mode recommendation.
8.  **Cleanup**: Intelligent removal of bulky raw data (SLC/DEM/Orbit) and intermediate ISCE products to save massive disk space, retaining only final high-value results.

## 3. Prerequisites

* **ISCE2 (v2.6+)**: Must be installed and loaded in your system (`topsApp.py`, `stackSentinel.py`, and `dem.py` must be in PATH).
* **Linux**: Recommended for ISCE2 compatibility.
* **wget**: Used for robust file downloading.
* **Python Dependencies**: `pip install numpy matplotlib requests gdal`
* **NASA Earthdata Credentials**: You must have a `~/.netrc` file configured with your NASA Earthdata login to download SLCs and Orbits from ASF. (`chmod 600 ~/.netrc`).

## 4. Installation & Environment Setup
**1. Clone the Repository & Make the Script Executable**
First, clone the repository to your local machine, and ensure the main script has execution permissions:
```bash
git clone https://github.com/limingjia92/autoInSAR.git
cd autoInSAR
chmod 755 autoInSAR.py
```

**2. Add to System PATH (Recommended)**
To run `autoInSAR` from any working directory (e.g., your project folder), add the installation directory to your `~/.bashrc` or `~/.zshrc file`:
```bash
# Add this to the end of your ~/.bashrc
export PATH="/path/to/autoInSAR:$PATH"
```
Then, refresh your shell:
```bash
source ~/.bashrc
```

Now you can simply run `autoInSAR.py --lon ...` from any folder.

## 5. Usage Examples

The script is run via the command line. You must provide the spatial center (`--lon`, `--lat`) and temporal information.

### [Mode A] Pair (D-InSAR)

**1. Earthquake / Event Mode:** Automatically searches for a pair of images ±12 days around a specific event date.
```bash
python autoInSAR.py --mode pair --lon 40.7 --lat 13.6 --event_date 20251117 --platform S1A
```

**2. Manual Pair Mode:** Manually specify the Reference and Secondary dates.
```bash
python autoInSAR.py --mode pair --lon 40.7 --lat 13.6 --reference_date 20251113 --secondary_date 20251125
```

### [Mode B] Stack (Time-Series for StaMPS-HPC)

**3. Time-Series Preparation:** Prepare a massive stack of coregistered SLCs for StaMPS. Note: Time-series strictly requires processing on a single satellite track, so `--rel_orbit` is highly recommended/enforced.
```bash
python autoInSAR.py --mode stack --lon 40.7 --lat 13.6 --start_date 20200101 --end_date 20231231 --rel_orbit 14
```

### [General] Running Specific Steps
You can run the pipeline step-by-step using the `--step` argument. Useful for debugging or re-running parts of the workflow.

```bash
python autoInSAR.py --mode stack --step clean
```

**Options:** `search`, `download`, `orbit`, `dem`, `xml`, `isce`, `post`, `all` (default), `clean`.

## 6. Arguments

| Argument           | Type   | Required | Description |
| :---               | :---   | :---     | :--- |
| `--mode`           | String | No       | Execution mode: `pair` or `stack`. (Default: `pair`) |
| `--lon`            | Float  | Yes      | Center Longitude of the area of interest. |
| `--lat`            | Float  | Yes      | Center Latitude of the area of interest. |
| `--event_date`     | String | No* | *[Pair Mode]* Event date (YYYYMMDD). Auto-selects pair ±12 days. |
| `--reference_date` | String | No* | *[Pair Mode]* Manual Reference date (YYYYMMDD). |
| `--secondary_date` | String | No* | *[Pair Mode]* Manual Secondary date (YYYYMMDD). |
| `--start_date`     | String | No** | *[Stack Mode]* Start date for time-series search (YYYYMMDD). |
| `--end_date`       | String | No** | *[Stack Mode]* End date for time-series search (YYYYMMDD). |
| `--platform`       | String | No       | Satellite platform (Default: `S1`). |
| `--rel_orbit`      | Int    | No*** | Specific Relative Orbit Number to filter results. |
| `--dlonlat`        | Float  | No       | Search buffer size in degrees (Default: `0.2`). |
| `--step`           | String | No       | Execution step (Default: `all`). |

*\* Pair Mode requires either `--event_date` OR both `--reference_date` and `--secondary_date`.*
*\*\* Stack Mode requires both `--start_date` and `--end_date`.*
*\*\*\* Time-Series (Stack Mode) MUST be conducted on a SINGLE relative orbit. Specifying `--rel_orbit` is highly recommended.*

## 7. Output Structure

After a successful run and cleanup (Step 8), the output directory will be drastically simplified to retain only the most valuable data.

### Stack Mode (Time-Series) Outputs:
```text
├── process/
│   ├── run_* # ISCE2 stack generation scripts (01 to 13)
│   └── merged/                 
│       ├── SLC/                # Perfectly coregistered SLC stack (Ready for StaMPS-HPC)
│       ├── baselines/          # Baseline grids
│       └── geom_reference/     # Topographic geometry (lat, lon, hgt, shadow/layover masks)
└── results/
    ├── stack_baselines_PS_*.png    # PS baseline network plot with optimal master highlighted
    ├── stack_baselines_SBAS_*.png  # SBAS baseline network plot based on temporal neighbors
    └── stamps_hpc_commands.txt     # Auto-generated terminal commands for StaMPS-HPC
```

### Pair Mode (D-InSAR) Outputs:
```text
├── process/
│   ├── tops.xml                # ISCE2 configuration file
│   └── merged/                 # Filtered unwrapped phase, coherence, offsets, etc.
└── results/
    ├── los_disp.grd            # Line-of-Sight Displacement (m)
    ├── coherence.grd           # Interferometric Coherence
    ├── vec_E.grd / vec_N.grd   # 3D Decomposition vectors (East/North)
    ├── offset_range.grd        # Pixel-offset in Range direction (m)
    ├── offset_azimuth.grd      # Pixel-offset in Azimuth direction (m)
    └── plot_asc_XX/            # Publication-ready PNG Visualizations
```

## 8. License

This project is licensed under the MIT License - see the source code for details.

Author: Mingjia Li
Copyright (c) 2026 Mingjia Li