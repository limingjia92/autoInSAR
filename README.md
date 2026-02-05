# autoInSAR: Automated Sentinel-1 InSAR Processing Pipeline

-----------------------------------------------------------------------

**autoInSAR** is a fully automated Differential InSAR (D-InSAR) processing pipeline designed for **Sentinel-1** data. 

It serves as a high-level wrapper around the **ISCE2** (InSAR Scientific Computing Environment) software, automating the entire lifecycle of interferometry—from data search and download to interferogram generation and result visualization.

## 1. Features

The pipeline automates the following 8 steps:

1.  **Search**: Auto-query SLC images from ASF API based on an event date (Earthquake mode) or specific dates.
2.  **Download**: Sequential downloading of SLC data with integrity verification.
3.  **Orbit**: Auto-fetch Precision (POEORB) or Restituted (RESORB) orbit files.
4.  **DEM**: Auto-download and stitch SRTMGL1 DEM tiles covering the area of interest.
5.  **Config**: Auto-generation of ISCE XML configuration files (`tops.xml`, etc.).
6.  **Process**: Execution of the standard `topsApp.py` workflow (startup -> geocodeoffsets).
7.  **Post-Processing**: Result extraction, cropping, E/N/U decomposition, and Plotting.
8.  **Cleanup**: (Optional) Intelligent removal of bulky raw data and intermediate ISCE products, retaining only final results.

## 2. Prerequisites

### System Requirements
* **ISCE2 (v2.6+)**: This script requires the ISCE2 environment to be installed and loaded in your system (`topsApp.py` and `dem.py` must be in PATH).
* **Linux**: Recommended for ISCE2 compatibility.
* **wget**: Used for file downloading.

### Python Dependencies
Ensure the following Python packages are installed in your ISCE environment:

    pip install numpy matplotlib requests
    
    # osgeo (gdal) is usually included with ISCE

### NASA Earthdata Credentials
You must have a `~/.netrc` file configured with your NASA Earthdata login to download SLCs and Orbits from ASF.

File: `~/.netrc`

    machine urs.earthdata.nasa.gov login <USERNAME> password <PASSWORD>

*Run `chmod 600 ~/.netrc` after creating the file.*

## 3. Installation

Clone this repository to your local machine:

    git clone https://github.com/your-username/autoInSAR.git
    cd autoInSAR

## 4. Usage

The script is run via command line. You must provide the spatial center (`--lon`, `--lat`) and temporal information.

### Mode 1: Event / Earthquake Mode
Automatically searches for a pair of images ±12 days around a specific event date.

    # Example: Process an event on Nov 17, 2025
    python autoInSAR.py --lon 40.7 --lat 13.6 --event_date 20251117 --platform S1A

### Mode 2: Manual Pair Mode
Manually specify the Reference (Master) and Secondary (Slave) dates.

    python autoInSAR.py --lon 40.7 --lat 13.6 \
        --reference_date 20251113 \
        --secondary_date 20251125

### Mode 3: Specific Orbit Processing
If multiple satellite tracks cover your area, specify the relative orbit number to filter the search.

    python autoInSAR.py ... --rel_orbit 14

### Running Specific Steps
You can run the pipeline step-by-step using the `--step` argument. Useful for debugging or re-running parts of the workflow.

**Options:** `search`, `download`, `orbit`, `dem`, `xml`, `isce`, `post`, `all` (default).

    # Example: Only run post-processing (result extraction & plotting)
    python autoInSAR.py --step post

## 5. Arguments

| Argument           | Type   | Required | Description |
| :---               | :---   | :---     | :--- |
| `--lon`            | Float  | Yes      | Center Longitude of the area of interest. |
| `--lat`            | Float  | Yes      | Center Latitude of the area of interest. |
| `--event_date`     | String | No* | Event date (YYYYMMDD). Auto-selects pair ±12 days. |
| `--reference_date` | String | No* | Manual Reference date (YYYYMMDD). |
| `--secondary_date` | String | No* | Manual Secondary date (YYYYMMDD). |
| `--platform`       | String | No       | Satellite platform (Default: `S1`). |
| `--rel_orbit`      | Int    | No       | Specific Relative Orbit Number to filter results. |
| `--dlonlat`        | Float  | No       | Search buffer size in degrees (Default: `0.2`). |
| `--step`           | String | No       | Execution step (Default: `all`). |

*\* Note: You must provide either `--event_date` OR both `--reference_date` and `--secondary_date`. for search step*

## 6. Output Structure

After a successful run, the following directory structure is created:

    ├── SLC/                    # Downloaded Sentinel-1 SLC data (.zip)
    ├── orbits/                 # Precise/Restituted Orbit files (.EOF)
    ├── DEM/                    # Downloaded and stitched DEM files
    ├── list_XX.txt             # file contains the SLC data name
    ├── url_XX.txt              # file contains the SLC data url
    ├── process/                # ISCE processing directory (contains tops.xml)
    │   ├── merged/             # Final ISCE output products
    │   ├── tops.xml            # Configuration files for isce2 process flow
    │   ├── reference.xml       # Configuration files for isce2 reference info
    │   ├── secondary.xml       # Configuration files for isce2 secondary info
    │   └── ../                 
    └── results/                # Final Results Grds and Plots
        ├── los_disp.grd        # Line-of-Sight Displacement (m)
        ├── coherence.grd       # Interferometric Coherence
        ├── wrap_phase.grd      # Wrapped Phase
        ├── vec_E.grd           # East decomposition vector
        ├── vec_N.grd           # North decomposition vector
        ├── vec_U.grd           # Vertical decomposition vector
        ├── offset_range.grd    # Pixel-offset in Range direction (m)
        ├── offset_azimuth.grd  # Pixel-offset in Azimuth direction (m)
        ├── snr.grd             # Signal-to-Noise Ratio for Pixel-offset
        └── plot_asc_XX/        # PNG Visualizations

## 7. License

This project is licensed under the MIT License - see the source code for details.

Author: Mingjia Li
Copyright (c) 2026 Mingjia Li