#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# S1_gamma_process.sh
#
# v3.0 release update:
#   - generic release configuration: PROJECT_ROOT can be supplied by --project-root,
#     environment, or a trusted --config file; REF/SEC/POL default to PREPARED_INPUTS.txt.
#   - safe production defaults: reuse valid caches and generate wrapped-phase QC first.
#   - add --check-only dependency/input validation and prepared-input consistency checks.
#   - all commonly tuned parameters can be overridden from an environment/config file.
#   - retain the v2.4 all-swath mosaic, azimuth-tail, full-extent plotting, and DEM-edge guards.
#
# v2.4 update:
#   - tolerate small explicit-mosaic azimuth-length differences and use the full common extent.
#   - standard/same-generation pairs use explicit all-swath mosaics; native S1_coreg_TOPS
#     mosaics are reserved for cross-generation compatibility cases where external
#     re-mosaicking can break the common geometry.
#   - plotting defaults to the full geocoded grid; ROI cropping is opt-in.
#   - validate all-swath input tabs and record mosaic/geocoded dimensions to prevent
#     silent one-swath/narrow-footprint outputs.
#   - keep REF/SEC as the science/output direction; internal coregistration
#     may be automatically reversed for S1A-S1C/S1C-S1A burst-grid mismatch.
#   - add manual burst harmonization using SLC_copy_S1_TOPS before S1_coreg_TOPS.
#   - if internal coregistration is reversed, the complex differential interferogram
#     is phase-conjugated so wrapped phase, unwrapped phase, LOS, GRD, and plots
#     stay in the science direction: SEC - REF.
#   - automatically disable legacy SLC_intf range/azimuth common-band filtering
#     for S1A-S1C/S1C-S1A pairs; the old GAMMA metadata path can otherwise suppress
#     an entire IW swath even when coregistration is valid.
#   - for cross-generation S1A-S1C all-swath processing, derive a per-IW burst
#     window from burst start times (time_align), then accept a result only after
#     per-swath coherence QC. Global first/last/no-selection remain fallbacks.
#   - same-satellite pairs, including S1C-S1C, retain standard order, no manual
#     burst selection, and standard common-band filtering.
#   - trial failures are kept in per-candidate logs; visible [ERROR] messages are
#     reserved for final failure after all configured candidates fail.
#
# Sentinel-1 TOPS / GAMMA interferogram, filtering, unwrapping,
# geocoding, plotting, and GRD export for one interferometric pair.
#
# Designed to run after:
#   ./S1_gamma_prepare_v2.sh
#
# Required prepared inputs under PROJECT_ROOT:
#   tabs/${REF}_${POL}.SLC_tab
#   tabs/${SEC}_${POL}.SLC_tab
#   dem/EQA.dem
#   dem/EQA.dem_par
#
# Typical usage:
#   1) Edit Section 0A/0B for the new pair and ROI.
#   2) First QC run: set DO_UNWRAP=0 to generate wrapped phase/coherence/GRD.
#   3) If direct unwrapping works, use UNW_ENGINE="mk_unw_2d".
#   4) If direct unwrapping crosses a rupture/branch incorrectly, pick
#      unwrap_branch_cut_lonlat.txt with pick_branch_cut_lonlat.m and use
#      UNW_ENGINE="mk_unw_2d_branch_cut".
#
# Supported UNW_ENGINE values:
#   none                  : no unwrapping; writes wrapped phase/coherence products.
#   snaphu                : direct whole-scene SNAPHU unwrap.
#   gamma_mcf             : direct whole-scene GAMMA mcf unwrap.
#   mk_unw_2d             : direct whole-scene GAMMA mk_unw_2d unwrap.
#   mk_unw_2d_branch_cut  : recommended special-case mode; two sides of a
#                           manual branch-cut are unwrapped independently with
#                           mk_unw_2d and independently zeroed to far-field boxes.
#
# Output highlights:
#   ADF-level wrapped phase/coherence:  ${ADF_DIR}/geocode/EQA.*phase / *.cc
#   GRD products:                      ${GRD_DIR}/wrap_phase.grd, coherence.grd,
#                                       los_disp.grd, los_disp_raw.grd
#   ROI plots:                         ${PLOT_DIR}
#   run summary:                       ${ADF_DIR}/RUN_SUMMARY.txt
#
# Notes:
#   - The coregistration cache is separated from look/ADF/unwrapping tests.
#   - Changing only RLKS/ALKS does not rerun S1_coreg_TOPS.
#   - Changing only ADF or unwrapping parameters reuses earlier cache when possible.
#   - los_disp.grd is in meters. Plot labels may display cm.
# ============================================================

# ============================================================
# Release configuration bootstrap
# ============================================================
SCRIPT_VERSION="3.0.0"
CONFIG_FILE="${CONFIG_FILE:-}"
CHECK_ONLY=0
PRINT_CONFIG=0
CLI_PROJECT_ROOT=""
CLI_REF=""
CLI_SEC=""
CLI_POL=""
CLI_FORCE_MODE=""
CLI_DO_UNWRAP=""
CLI_UNW_ENGINE=""

usage(){
  cat <<'TXT'
S1_gamma_process.sh

Usage:
  S1_gamma_process.sh --project-root DIR [options]
  S1_gamma_process.sh --config FILE [options]

Required project layout (created by S1_gamma_prepare.sh):
  DIR/PREPARED_INPUTS.txt
  DIR/tabs/YYYYMMDD_pol.SLC_tab
  DIR/dem/EQA.dem
  DIR/dem/EQA.dem_par

Options:
  --project-root DIR   GAMMA project directory.
  --config FILE        Source a trusted Bash environment/config file first.
  --ref YYYYMMDD       Override science reference date.
  --sec YYYYMMDD       Override science secondary date.
  --pol POL            Override polarization (vv/vh/hh/hv).
  --check-only         Validate configuration, inputs, Python modules, and commands; do not process.
  --print-config       Print resolved key configuration before processing.
  --force-all          Rebuild every processing level.
  --reuse              Reuse valid caches; missing products are still generated.
  --unwrap ENGINE      Enable unwrapping with: snaphu, gamma_mcf, mk_unw_2d,
                       or mk_unw_2d_branch_cut.
  --no-unwrap          Generate wrapped phase/coherence only.
  -h, --help           Show this help.

Examples:
  ./S1_gamma_process.sh --project-root /data/GAMMA_PAIR --check-only
  ./S1_gamma_process.sh --project-root /data/GAMMA_PAIR --no-unwrap
  ./S1_gamma_process.sh --config pair.env --unwrap mk_unw_2d

Environment variables override defaults. A config file may contain ordinary Bash
assignments such as PROJECT_ROOT=..., PLOT_COH_THRESHOLD=0.10, and DO_UNWRAP=0.
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) [[ $# -ge 2 ]] || { echo "[ERROR] --project-root requires a value" >&2; exit 2; }; CLI_PROJECT_ROOT="$2"; shift 2 ;;
    --config)       [[ $# -ge 2 ]] || { echo "[ERROR] --config requires a value" >&2; exit 2; }; CONFIG_FILE="$2"; shift 2 ;;
    --ref)          [[ $# -ge 2 ]] || { echo "[ERROR] --ref requires a value" >&2; exit 2; }; CLI_REF="$2"; shift 2 ;;
    --sec)          [[ $# -ge 2 ]] || { echo "[ERROR] --sec requires a value" >&2; exit 2; }; CLI_SEC="$2"; shift 2 ;;
    --pol)          [[ $# -ge 2 ]] || { echo "[ERROR] --pol requires a value" >&2; exit 2; }; CLI_POL="$2"; shift 2 ;;
    --check-only)   CHECK_ONLY=1; shift ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    --force-all)    CLI_FORCE_MODE="force"; shift ;;
    --reuse)        CLI_FORCE_MODE="reuse"; shift ;;
    --unwrap)       [[ $# -ge 2 ]] || { echo "[ERROR] --unwrap requires an engine" >&2; exit 2; }; CLI_DO_UNWRAP=1; CLI_UNW_ENGINE="$2"; shift 2 ;;
    --no-unwrap)    CLI_DO_UNWRAP=0; CLI_UNW_ENGINE="none"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "[ERROR] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] config file not found: $CONFIG_FILE" >&2; exit 2; }
  # Config files are trusted user input and may use Bash parameter expansion.
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

[[ -n "$CLI_PROJECT_ROOT" ]] && PROJECT_ROOT="$CLI_PROJECT_ROOT"
[[ -n "$CLI_REF" ]] && REF="$CLI_REF"
[[ -n "$CLI_SEC" ]] && SEC="$CLI_SEC"
[[ -n "$CLI_POL" ]] && POL="$CLI_POL"
if [[ "$CLI_FORCE_MODE" == "force" ]]; then
  FORCE_COREG=1; FORCE_MOSAIC=1; FORCE_LOOK=1; FORCE_ADF=1; FORCE_SNAPHU=1; FORCE_PLOT=1; FORCE_GRD=1
elif [[ "$CLI_FORCE_MODE" == "reuse" ]]; then
  FORCE_COREG=0; FORCE_MOSAIC=0; FORCE_LOOK=0; FORCE_ADF=0; FORCE_SNAPHU=0; FORCE_PLOT=0; FORCE_GRD=0
fi
[[ -n "$CLI_DO_UNWRAP" ]] && DO_UNWRAP="$CLI_DO_UNWRAP"
[[ -n "$CLI_UNW_ENGINE" ]] && UNW_ENGINE="$CLI_UNW_ENGINE"

# Convenient inference when the command is launched from a prepared project root.
if [[ -z "${PROJECT_ROOT:-}" && -f "$PWD/PREPARED_INPUTS.txt" ]]; then
  PROJECT_ROOT="$PWD"
fi
if [[ -z "${PROJECT_ROOT:-}" ]]; then
  echo "[ERROR] PROJECT_ROOT is required. Use --project-root DIR, --config FILE, or run from a prepared project directory." >&2
  exit 2
fi
PROJECT_ROOT=$(readlink -f "$PROJECT_ROOT")
[[ -d "$PROJECT_ROOT" ]] || { echo "[ERROR] PROJECT_ROOT does not exist: $PROJECT_ROOT" >&2; exit 2; }

PREPARED_INPUTS_FILE="${PREPARED_INPUTS_FILE:-${PROJECT_ROOT}/PREPARED_INPUTS.txt}"
prepare_value(){
  local key="$1"
  [[ -f "$PREPARED_INPUTS_FILE" ]] || return 0
  awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$PREPARED_INPUTS_FILE"
}
PREP_REF=$(prepare_value REF)
PREP_SEC=$(prepare_value SEC)
PREP_POL=$(prepare_value POL)
PREP_DEM=$(prepare_value DEM)
PREP_DEM_PAR=$(prepare_value DEM_PAR)

# ============================================================
# 0A. Pair-specific settings: normally PROJECT_ROOT is the only required input
# ============================================================
REF="${REF:-${PREP_REF:-}}"        # SCIENCE reference/master date; never reverse manually
SEC="${SEC:-${PREP_SEC:-}}"        # SCIENCE secondary/slave date; output phase/LOS is SEC-REF
POL="${POL:-${PREP_POL:-vv}}"      # polarization in prepared SLC_tab names
[[ -n "$REF" && -n "$SEC" ]] || { echo "[ERROR] REF/SEC are missing and were not found in $PREPARED_INPUTS_FILE" >&2; exit 2; }
PAIR="${REF}_${SEC}"
WORKDIR="${WORKDIR:-${PROJECT_ROOT}/ifg_${PAIR}}"

# Inputs produced by S1_gamma_prepare_v2.sh. Explicit environment/config values win.
REF_TAB="${REF_TAB:-${PROJECT_ROOT}/tabs/${REF}_${POL}.SLC_tab}"
SEC_TAB="${SEC_TAB:-${PROJECT_ROOT}/tabs/${SEC}_${POL}.SLC_tab}"
DEM="${DEM:-${PREP_DEM:-${PROJECT_ROOT}/dem/EQA.dem}}"
DEM_PAR="${DEM_PAR:-${PREP_DEM_PAR:-${PROJECT_ROOT}/dem/EQA.dem_par}}"

# ROI used for plots and optional GRD cropping. Keep broader than the rupture/target area.
ROI_LON_MIN="${ROI_LON_MIN:--180}"
ROI_LON_MAX="${ROI_LON_MAX:-180}"
ROI_LAT_MIN="${ROI_LAT_MIN:--90}"
ROI_LAT_MAX="${ROI_LAT_MAX:-90}"

# Optional marker, for example earthquake epicenter. Set MARKER_ON=0 to disable.
MARKER_ON="${MARKER_ON:-0}"
MARKER_LON="${MARKER_LON:-0.0}"
MARKER_LAT="${MARKER_LAT:-0.0}"

# ============================================================
# 0B. Main processing choices: commonly adjusted during tests
# ============================================================
# Re-run controls. Release defaults reuse valid caches; missing products are always generated.
FORCE_COREG="${FORCE_COREG:-0}"        # rerun S1_coreg_TOPS and mosaic cache; set 1 for a new pair
FORCE_MOSAIC="${FORCE_MOSAIC:-0}"       # rerun TOPS mosaics; auto selects explicit/native according to pair type
FORCE_LOOK="${FORCE_LOOK:-0}"         # rerun multilook/interferogram/geocode/topo-removal
FORCE_ADF="${FORCE_ADF:-0}"          # rerun ADF filtering
FORCE_SNAPHU="${FORCE_SNAPHU:-0}"       # rerun unwrapping/reference/LOS
FORCE_PLOT="${FORCE_PLOT:-1}"         # regenerate ROI plots
FORCE_GRD="${FORCE_GRD:-1}"          # regenerate GRD products

# Final interferogram looks. 20x5 is a good high-resolution starting point for Sentinel-1 TOPS.
RLKS="${RLKS:-20}"
ALKS="${ALKS:-5}"

# ADF filtering. Increase smoothing only if coherence/noise requires it.
ADF_ALPHA="${ADF_ALPHA:-0.85}"
ADF_NFFT="${ADF_NFFT:-64}"
ADF_CCWIN="${ADF_CCWIN:-7}"

# Unwrapping mode. Recommended sequence:
#   none -> inspect wrap/coherence; mk_unw_2d -> direct unwrap; mk_unw_2d_branch_cut -> special rupture cases.
DO_UNWRAP="${DO_UNWRAP:-1}"
UNW_ENGINE="${UNW_ENGINE:-mk_unw_2d}"     # none, snaphu, gamma_mcf, mk_unw_2d, mk_unw_2d_branch_cut
UNW_COH_THRESHOLD="${UNW_COH_THRESHOLD:-0.15}"     # coherence threshold used by unwrap mask/weights

# Manual branch-cut settings, used only when UNW_ENGINE="mk_unw_2d_branch_cut".
# The file is lon lat, one point per line. Pick it from wrap_phase.grd/coherence.grd.
BRANCH_CUT_FILE="${BRANCH_CUT_FILE:-unwrap_branch_cut_lonlat.txt}"
BRANCH_BUFFER_KM="${BRANCH_BUFFER_KM:-0.1}"       # half-width of no-join strip around branch-cut; test 0.1/0.3/0.5
BRANCH_ORIENT_BY_REF_BOX="${BRANCH_ORIENT_BY_REF_BOX:-1}" # orient arbitrary branch side so NORTH_REF_BOX falls on the north side

# Side-wise far-field reference boxes for branch-cut mode.
# Tune these for each event; they must lie in stable far field on each side.
NORTH_REF_LON_MIN="${NORTH_REF_LON_MIN:-0}"
NORTH_REF_LON_MAX="${NORTH_REF_LON_MAX:-0}"
NORTH_REF_LAT_MIN="${NORTH_REF_LAT_MIN:-0}"
NORTH_REF_LAT_MAX="${NORTH_REF_LAT_MAX:-0}"
SOUTH_REF_LON_MIN="${SOUTH_REF_LON_MIN:-0}"
SOUTH_REF_LON_MAX="${SOUTH_REF_LON_MAX:-0}"
SOUTH_REF_LAT_MIN="${SOUTH_REF_LAT_MIN:-0}"
SOUTH_REF_LAT_MAX="${SOUTH_REF_LAT_MAX:-0}"

# GRD output masks. los_disp.grd is usually the file used by later inversion.
DO_WRITE_GRD="${DO_WRITE_GRD:-1}"
GRD_CROP_TO_ROI="${GRD_CROP_TO_ROI:-0}"  # 1 = crop outputs to ROI; 0 = full geocoded map extent
GRD_APPLY_COH_MASK="${GRD_APPLY_COH_MASK:-1}"       # 1 = mask low-coherence pixels in GRD outputs
GRD_COH_THRESHOLD="${GRD_COH_THRESHOLD:-0.20}"
GRD_APPLY_WATER_MASK="${GRD_APPLY_WATER_MASK:-1}"
GRD_WATER_DEM_THRESHOLD="${GRD_WATER_DEM_THRESHOLD:-0.0}"

# For direct whole-scene unwrapping, optional map-grid LOS reference correction.
# For branch-cut mode, keep this as none because side-wise reference is already applied.
GRD_LOS_REF_MODE="${GRD_LOS_REF_MODE:-none}"    # none, output_median, global, box
GRD_LOS_REF_LON_MIN="${GRD_LOS_REF_LON_MIN:-0}"
GRD_LOS_REF_LON_MAX="${GRD_LOS_REF_LON_MAX:-0}"
GRD_LOS_REF_LAT_MIN="${GRD_LOS_REF_LAT_MIN:-0}"
GRD_LOS_REF_LAT_MAX="${GRD_LOS_REF_LAT_MAX:-0}"

# ============================================================
# 0C. Advanced defaults: rarely changed
# ============================================================
# Coregistration settings. These are independent from final RLKS/ALKS.
COREG_RLKS="${COREG_RLKS:-20}"
COREG_ALKS="${COREG_ALKS:-5}"
COREG_ENGINE="${COREG_ENGINE:-auto}"       # auto: use S1_coreg_TOPS; none: assume RSLC tab already exists
COREG_HGT="${COREG_HGT:-0.1}"
COREG_CC_THRESH="${COREG_CC_THRESH:-0.8}"
COREG_FRACTION_THRESH="${COREG_FRACTION_THRESH:-0.01}"
COREG_PH_STDEV_THRESH="${COREG_PH_STDEV_THRESH:-0.8}"
COREG_CLEANING="${COREG_CLEANING:-0}"
COREG_USE_EXISTING="${COREG_USE_EXISTING:-0}"
SWATHS_TO_PROCESS="${SWATHS_TO_PROCESS:-all}"   # production default: all; diagnostics: iw1/iw2/iw3
MOSAIC_SOURCE_MODE="${MOSAIC_SOURCE_MODE:-auto}" # auto/native/explicit; auto uses explicit for standard pairs, native for S1A-S1C compatibility
SLC_INTF_MAX_AZ_LINE_MISMATCH="${SLC_INTF_MAX_AZ_LINE_MISMATCH:-${ALKS}}" # tolerate <= this many full-resolution azimuth lines; process the common extent
REPAIR_ZERO_RSLCPAR="${REPAIR_ZERO_RSLCPAR:-0}"
REPAIR_SOURCE="${REPAIR_SOURCE:-secondary}"
COREG_STRICT_CLEAN="${COREG_STRICT_CLEAN:-1}"   # when FORCE_COREG=1, remove the whole coreg cache to avoid stale empty *.slc.par/*.rslc files

# v1.2 S1A-S1C burst-grid compatibility layer.
# Leave REF/SEC above in the science/output direction. In auto mode, the script
# may internally coregister with S1C as reference and S1A as secondary, then flip
# final phase/LOS sign back to the science direction.
COREG_ORDER="${COREG_ORDER:-auto}"                 # auto, as_science, reversed
COREG_BURST_SELECT="${COREG_BURST_SELECT:-auto}"     # auto, none, manual_count
COREG_BURST_STRATEGY="${COREG_BURST_STRATEGY:-auto}" # auto, time_align, last9, first9
OUTPUT_SIGN_MODE="${OUTPUT_SIGN_MODE:-auto}"         # auto, +1, -1
COREG_BURST_KEEP_FAILED_TRIALS="${COREG_BURST_KEEP_FAILED_TRIALS:-1}"    # keep failed trial logs/directories for diagnostics

# SLC_intf common-band filtering.
# auto => OFF for S1A-S1C/S1C-S1A (required by the tested legacy GAMMA build),
#         ON for same-satellite pairs including S1C-S1C and for other standard pairs.
SPS_FLG="${SPS_FLG:-auto}"          # auto, 0, 1
AZF_FLG="${AZF_FLG:-auto}"          # auto, 0, 1
RP1_FLG="${RP1_FLG:-1}"
RP2_FLG="${RP2_FLG:-1}"
AZ_BETA="${AZ_BETA:-2.120}"

# Automatic compatibility dispatcher and coherence QC.
AUTO_COMPAT_MODE="${AUTO_COMPAT_MODE:-1}"      # 1: quiet candidate trials for cross S1A-S1C all-swath pairs
AUTO_TRIAL_CHILD="${AUTO_TRIAL_CHILD:-0}"      # internal; do not edit
QC_ENABLE="${QC_ENABLE:-1}"
QC_ENFORCE="${QC_ENFORCE:-0}"                  # dispatcher children set this to 1
QC_MIN_SWATH_NONZERO="${QC_MIN_SWATH_NONZERO:-0.10}"
QC_MIN_SWATH_MEAN="${QC_MIN_SWATH_MEAN:-0.03}"
QC_MIN_SWATH_P75="${QC_MIN_SWATH_P75:-0.08}"
QC_ZERO_EPS="${QC_ZERO_EPS:-1e-6}"
RESULT_MANIFEST_PATH="${RESULT_MANIFEST_PATH:-}"
ALLOW_PREPARED_MISMATCH="${ALLOW_PREPARED_MISMATCH:-0}"
PUBLISH_FINAL="${PUBLISH_FINAL:-1}"

# Direct unwrap / LOS conversion settings.
SNAPHU_COST_MODE="${SNAPHU_COST_MODE:-DEFO}"
SNAPHU_INIT_METHOD="${SNAPHU_INIT_METHOD:-MCF}"
SNAPHU_NCORRLOOKS="${SNAPHU_NCORRLOOKS:-20}"
SNAPHU_EXTRA_OPTS="${SNAPHU_EXTRA_OPTS:-}"
WAVELENGTH_M="${WAVELENGTH_M:-0.05546576}"   # Sentinel-1 C-band wavelength, meters
LOS_SIGN="${LOS_SIGN:--1}"               # LOS_m = LOS_SIGN * unw_phase * wavelength/(4*pi)
SNAPHU_CORR_FLOOR="${SNAPHU_CORR_FLOOR:-0.00001}"

# Reference/masking for direct unwrap modes. Branch-cut mode overrides reference with side-wise boxes.
UNW_REF_MODE="${UNW_REF_MODE:-global}"       # direct modes: none or global; branch-cut mode forces side-wise box logic
UNW_REF_COH_THRESHOLD="${UNW_REF_COH_THRESHOLD:-0.30}"
UNW_REMOVE_PLANE="${UNW_REMOVE_PLANE:-0}"
UNW_OUTPUT_APPLY_MASK="${UNW_OUTPUT_APPLY_MASK:-0}"
UNW_OUTPUT_COH_THRESHOLD="${UNW_OUTPUT_COH_THRESHOLD:-0.20}"
UNW_OUTPUT_WATER_MASK="${UNW_OUTPUT_WATER_MASK:-1}"
UNW_OUTPUT_WATER_THRESHOLD="${UNW_OUTPUT_WATER_THRESHOLD:-0.0}"

# mk_unw_2d parameters for both direct and branch-cut modes.
MKUNW_CC_THRES="${MKUNW_CC_THRES:-0.35}"
MKUNW_PWR_THRES="${MKUNW_PWR_THRES:-0.0}"
MKUNW_NLKS="${MKUNW_NLKS:-2}"
MKUNW_NPAT_R="${MKUNW_NPAT_R:-1}"
MKUNW_NPAT_AZ="${MKUNW_NPAT_AZ:-1}"
MKUNW_MODE="${MKUNW_MODE:-1}"
MKUNW_R_INIT="${MKUNW_R_INIT:--}"
MKUNW_AZ_INIT="${MKUNW_AZ_INIT:--}"
MKUNW_TRI_MODE="${MKUNW_TRI_MODE:-1}"
MKUNW_MASK="${MKUNW_MASK:--}"
MKUNW_ROFF="${MKUNW_ROFF:-0}"
MKUNW_LOFF="${MKUNW_LOFF:-0}"
MKUNW_NR="${MKUNW_NR:--}"
MKUNW_NLINES="${MKUNW_NLINES:--}"

# Branch-cut side-mask defaults.
NS_REF_COH_THRESHOLD="${NS_REF_COH_THRESHOLD:-0.35}"
NS_MASK_WATER="${NS_MASK_WATER:-1}"
NS_MIN_REF_PIXELS="${NS_MIN_REF_PIXELS:-200}"
NS_MIN_REGION_PIXELS="${NS_MIN_REGION_PIXELS:-5000}"

# Plotting defaults.
PLOT_CROP_TO_ROI="${PLOT_CROP_TO_ROI:-0}" # 0 = full geocoded extent; 1 = crop to ROI
PLOT_COH_THRESHOLD="${PLOT_COH_THRESHOLD:-0.20}"
MASK_WATER="${MASK_WATER:-1}"
WATER_DEM_THRESHOLD="${WATER_DEM_THRESHOLD:-0.0}"
REMOVE_RAMP="${REMOVE_RAMP:-0}"
RAMP_FIT_COH_THRESHOLD="${RAMP_FIT_COH_THRESHOLD:-0.35}"

# Geocode refinement and interpolation.
LAT_OVR="${LAT_OVR:-1}"
LON_OVR="${LON_OVR:-1}"
GEO_OFF_WIN_R="${GEO_OFF_WIN_R:-128}"
GEO_OFF_WIN_A="${GEO_OFF_WIN_A:-128}"
GEO_OFF_OVR="${GEO_OFF_OVR:-1}"
GEO_OFF_NR="${GEO_OFF_NR:-256}"
GEO_OFF_NAZ="${GEO_OFF_NAZ:-256}"
GEO_OFF_CC_THR="${GEO_OFF_CC_THR:-0.10}"
GEO_FIT_CC_THR="${GEO_FIT_CC_THR:-0.70}"
GEO_FIT_NPAR="${GEO_FIT_NPAR:-3}"
GEOCODE_UNW_INTERP="${GEOCODE_UNW_INTERP:-0}"       # nearest-neighbor for unw/LOS; avoids smoothing across branch-cut gaps

# Geocoding extent guard. gc_map cannot create valid output outside the input DEM.
# If valid coherence reaches a geocoded edge that coincides with a source-DEM edge,
# the scene is almost certainly clipped by insufficient DEM coverage.
GEOCODE_EDGE_QC="${GEOCODE_EDGE_QC:-1}"
GEOCODE_FAIL_ON_DEM_EDGE_CLIP="${GEOCODE_FAIL_ON_DEM_EDGE_CLIP:-1}"
GEOCODE_EDGE_BAND_PIXELS="${GEOCODE_EDGE_BAND_PIXELS:-8}"
GEOCODE_EDGE_VALID_FRACTION="${GEOCODE_EDGE_VALID_FRACTION:-0.01}"
GEOCODE_EDGE_CC_EPS="${GEOCODE_EDGE_CC_EPS:-1e-6}"

# GRD export defaults.
GRD_DRIVER="${GRD_DRIVER:-GMT}"
GRD_WRITE_NAN_LOS_IF_NO_UNW="${GRD_WRITE_NAN_LOS_IF_NO_UNW:-0}"
GRD_LOS_REF_COH_THRESHOLD="${GRD_LOS_REF_COH_THRESHOLD:-0.20}"
GRD_LOS_REF_WATER_MASK="${GRD_LOS_REF_WATER_MASK:-1}"
GRD_LOS_REF_WATER_THRESHOLD="${GRD_LOS_REF_WATER_THRESHOLD:-0.0}"
GRD_WRITE_RAW_LOS="${GRD_WRITE_RAW_LOS:-1}"


# ============================================================
# 0D. v1.2 science direction -> internal coregistration direction
# ============================================================
# REF/SEC remain the science/output direction. COREG_REF/COREG_SEC are used only
# inside GAMMA coregistration. OUTPUT_PHASE_SIGN is applied after differential
# interferogram generation so all exported phase/LOS products remain SEC-REF.

tab_first_par(){
  awk 'NF>=2 && $1 !~ /^#/ {print $2; exit}' "$1" 2>/dev/null || true
}

tab_satellite(){
  local tab="$1" par sat
  par=$(tab_first_par "$tab")
  if [[ -z "${par:-}" || ! -s "$par" ]]; then echo "UNKNOWN"; return 0; fi
  sat=$(awk 'BEGIN{IGNORECASE=1}
    /S1A|Sentinel-1A|s1a/ {print "S1A"; exit}
    /S1B|Sentinel-1B|s1b/ {print "S1B"; exit}
    /S1C|Sentinel-1C|s1c/ {print "S1C"; exit}
    /S1D|Sentinel-1D|s1d/ {print "S1D"; exit}' "$par" 2>/dev/null || true)
  echo "${sat:-UNKNOWN}"
}

tab_max_bursts(){
  local tab="$1" slc par tops rest n max=0
  if [[ ! -f "$tab" ]]; then echo 0; return 0; fi
  while read -r slc par tops rest; do
    [[ -z "${slc:-}" || "${slc:0:1}" == "#" ]] && continue
    if [[ -s "$tops" ]]; then
      n=$(awk '$1=="number_of_bursts:" {print int($2); exit}' "$tops" 2>/dev/null || true)
      [[ -z "${n:-}" ]] && n=0
      if (( n > max )); then max=$n; fi
    fi
  done < "$tab"
  echo "$max"
}

is_s1a_s1c_pair(){
  [[ ( "$1" == "S1A" && "$2" == "S1C" ) || ( "$1" == "S1C" && "$2" == "S1A" ) ]]
}

REF_SAT=$(tab_satellite "$REF_TAB")
SEC_SAT=$(tab_satellite "$SEC_TAB")
REF_MAX_BURSTS=$(tab_max_bursts "$REF_TAB")
SEC_MAX_BURSTS=$(tab_max_bursts "$SEC_TAB")

COREG_REF="$REF"
COREG_SEC="$SEC"
COREG_ORDER_USED="as_science"

case "${COREG_ORDER}" in
  auto)
    if is_s1a_s1c_pair "$REF_SAT" "$SEC_SAT" && [[ "$REF_MAX_BURSTS" != "$SEC_MAX_BURSTS" ]]; then
      if [[ "$REF_SAT" == "S1C" ]]; then
        COREG_REF="$REF"; COREG_SEC="$SEC"; COREG_ORDER_USED="as_science"
      elif [[ "$SEC_SAT" == "S1C" ]]; then
        COREG_REF="$SEC"; COREG_SEC="$REF"; COREG_ORDER_USED="reversed"
      fi
    fi
    ;;
  as_science)
    COREG_REF="$REF"; COREG_SEC="$SEC"; COREG_ORDER_USED="as_science" ;;
  reversed)
    COREG_REF="$SEC"; COREG_SEC="$REF"; COREG_ORDER_USED="reversed" ;;
  *) echo "[ERROR] unknown COREG_ORDER=${COREG_ORDER}; use auto/as_science/reversed" >&2; exit 1 ;;
esac

COREG_REF_TAB_SRC="${PROJECT_ROOT}/tabs/${COREG_REF}_${POL}.SLC_tab"
COREG_SEC_TAB_SRC="${PROJECT_ROOT}/tabs/${COREG_SEC}_${POL}.SLC_tab"
COREG_REF_SAT=$(tab_satellite "$COREG_REF_TAB_SRC")
COREG_SEC_SAT=$(tab_satellite "$COREG_SEC_TAB_SRC")
COREG_REF_MAX_BURSTS=$(tab_max_bursts "$COREG_REF_TAB_SRC")
COREG_SEC_MAX_BURSTS=$(tab_max_bursts "$COREG_SEC_TAB_SRC")
COREG_PAIR="${COREG_REF}_${COREG_SEC}"

PAIR_IS_S1A_S1C=0
if is_s1a_s1c_pair "$REF_SAT" "$SEC_SAT"; then PAIR_IS_S1A_S1C=1; fi

resolve_binary_auto_flag(){
  local requested="$1" standard="$2" cross="$3" label="$4"
  case "$requested" in
    auto|AUTO|Auto)
      if [[ "$PAIR_IS_S1A_S1C" -eq 1 ]]; then echo "$cross"; else echo "$standard"; fi ;;
    0|1) echo "$requested" ;;
    *) echo "[ERROR] invalid ${label}=${requested}; use auto/0/1" >&2; exit 1 ;;
  esac
}
SPS_FLG_USED=$(resolve_binary_auto_flag "$SPS_FLG" 1 0 SPS_FLG)
AZF_FLG_USED=$(resolve_binary_auto_flag "$AZF_FLG" 1 0 AZF_FLG)
COMMON_BAND_TAG="cb${SPS_FLG_USED}${AZF_FLG_USED}"

case "${MOSAIC_SOURCE_MODE,,}" in
  auto)
    if [[ "$PAIR_IS_S1A_S1C" -eq 1 ]]; then
      MOSAIC_SOURCE_MODE_RESOLVED="native"
    else
      MOSAIC_SOURCE_MODE_RESOLVED="explicit"
    fi
    ;;
  native|explicit)
    MOSAIC_SOURCE_MODE_RESOLVED="${MOSAIC_SOURCE_MODE,,}"
    ;;
  *)
    echo "[ERROR] Invalid MOSAIC_SOURCE_MODE=${MOSAIC_SOURCE_MODE}; use auto/native/explicit" >&2
    exit 1
    ;;
esac

case "${OUTPUT_SIGN_MODE}" in
  auto)
    if [[ "$COREG_ORDER_USED" == "reversed" ]]; then OUTPUT_PHASE_SIGN=-1; else OUTPUT_PHASE_SIGN=1; fi ;;
  +1|1) OUTPUT_PHASE_SIGN=1 ;;
  -1) OUTPUT_PHASE_SIGN=-1 ;;
  *) echo "[ERROR] unknown OUTPUT_SIGN_MODE=${OUTPUT_SIGN_MODE}; use auto/+1/-1" >&2; exit 1 ;;
esac

COREG_BURST_SELECT_USED="none"
case "${COREG_BURST_SELECT}" in
  auto)
    if is_s1a_s1c_pair "$COREG_REF_SAT" "$COREG_SEC_SAT" && (( COREG_SEC_MAX_BURSTS > COREG_REF_MAX_BURSTS )); then
      COREG_BURST_SELECT_USED="manual_count"
    else
      COREG_BURST_SELECT_USED="none"
    fi
    ;;
  none|0|false|False|FALSE)
    COREG_BURST_SELECT_USED="none" ;;
  manual_count|manual|1|true|True|TRUE)
    COREG_BURST_SELECT_USED="manual_count" ;;
  *) echo "[ERROR] unknown COREG_BURST_SELECT=${COREG_BURST_SELECT}; use auto/none/manual_count" >&2; exit 1 ;;
esac

BSEL_TAG="bsel${COREG_BURST_SELECT_USED}_strat${COREG_BURST_STRATEGY}_sgn${OUTPUT_PHASE_SIGN}"

# -------------------------
# 1. Derived names and cache layout
# -------------------------
LOOK="${RLKS}x${ALKS}"
COREG_LOOK="${COREG_RLKS}x${COREG_ALKS}"

alpha_tag=$(python3 - <<PY
print(f"{int(round(float('${ADF_ALPHA}')*100)):03d}")
PY
)
cc_tag=$(python3 - <<PY
thr=float('${PLOT_COH_THRESHOLD}')
print('all' if thr <= 0 else f"{int(round(thr*100)):02d}")
PY
)
unwcc_tag=$(python3 - <<PY
thr=float('${UNW_COH_THRESHOLD}')
print(f"{int(round(thr*100)):02d}")
PY
)
SWATH_TAG=$(echo "$SWATHS_TO_PROCESS" | tr ',' '_' | tr 'A-Z' 'a-z' | tr -d ' ')
COREG_TAG="coreg_${COREG_ORDER_USED}_sw${SWATH_TAG}_${BSEL_TAG}_mos${MOSAIC_SOURCE_MODE_RESOLVED}_c${COREG_LOOK}_cc$(python3 - <<PY
print(f"{int(round(float('${COREG_CC_THRESH}')*100)):02d}")
PY
)"

COREG_DIR="${WORKDIR}/_${COREG_TAG}"
COREG_LOG_DIR="${COREG_DIR}/logs"
# If a previous S1_coreg_TOPS run failed, it may leave empty/stale files such as
# ${SEC}.slc.par or ${SEC}.rslc.par.  These can be silently reused by old GAMMA
# wrappers and cause misleading metadata warnings.  FORCE_COREG=1 now purges the
# entire coreg cache before rebuilding it.
if [[ "${FORCE_COREG}" -eq 1 && "${COREG_STRICT_CLEAN:-1}" -eq 1 && -d "$COREG_DIR" ]]; then
  echo "[$(date '+%F %T')] FORCE_COREG=1: remove stale coreg cache: $COREG_DIR" >&2
  rm -rf "$COREG_DIR"
fi
mkdir -p "$COREG_DIR" "$COREG_LOG_DIR"
COREG_BURST_STRATEGY_USED="none"

# Coreg cache products
REF_TAB_LOCAL="${COREG_DIR}/${COREG_REF}_${POL}.SLC_tab"
SEC_TAB_LOCAL="${COREG_DIR}/${COREG_SEC}_${POL}.SLC_tab"
SEC_TAB_FOR_COREG="${SEC_TAB_LOCAL}"
SEC_SELECTED_TAB_LOCAL="${COREG_DIR}/${COREG_SEC}_${POL}.selected.SLC_tab"
SEC_RSLC_TAB_LOCAL="${COREG_DIR}/${COREG_SEC}_${POL}.RSLC_tab"
REF_MOSAIC="${COREG_DIR}/${COREG_REF}_${POL}.slc"
REF_MOSAIC_PAR="${COREG_DIR}/${COREG_REF}_${POL}.slc.par"
SEC_MOSAIC="${COREG_DIR}/${COREG_SEC}_${POL}.rslc"
SEC_MOSAIC_PAR="${COREG_DIR}/${COREG_SEC}_${POL}.rslc.par"
OFF_COREG="${COREG_DIR}/${COREG_PAIR}.off"
BASE="${COREG_DIR}/${COREG_PAIR}.base_orbit"

# Look-level cache products
LOOK_DIR="${WORKDIR}/look_${LOOK}_${COREG_TAG}_${COMMON_BAND_TAG}"
LOOK_LOG_DIR="${LOOK_DIR}/logs"
LOOK_GEO_DIR="${LOOK_DIR}/geocode"
mkdir -p "$LOOK_DIR" "$LOOK_LOG_DIR" "$LOOK_GEO_DIR"

OFF_LOOK="${LOOK_DIR}/${PAIR}_${LOOK}.off"
REF_MLI="${LOOK_DIR}/${COREG_REF}_${LOOK}.mli"
REF_MLI_PAR="${LOOK_DIR}/${COREG_REF}_${LOOK}.mli.par"
SEC_RMLI="${LOOK_DIR}/${COREG_SEC}_${LOOK}.rmli"
SEC_RMLI_PAR="${LOOK_DIR}/${COREG_SEC}_${LOOK}.rmli.par"
INT="${LOOK_DIR}/${PAIR}_${LOOK}.int"
CC="${LOOK_DIR}/${PAIR}_${LOOK}.cc"
HGT="${LOOK_DIR}/${COREG_REF}_${LOOK}.hgt"
PH_SIM="${LOOK_DIR}/${PAIR}_${LOOK}.ph_sim"
DIFF_PAR="${LOOK_DIR}/${PAIR}_${LOOK}.diff_par"
DIFF0="${LOOK_DIR}/${PAIR}_${LOOK}.diff0"
DIFF0_PHASE="${LOOK_DIR}/${PAIR}_${LOOK}.diff0.phase"

# ADF-level products
ADF_TAG="adf${alpha_tag}_n${ADF_NFFT}_w${ADF_CCWIN}"
ADF_DIR="${LOOK_DIR}/${ADF_TAG}"
ADF_LOG_DIR="${ADF_DIR}/logs"
ADF_GEO_DIR="${ADF_DIR}/geocode"
mkdir -p "$ADF_DIR" "$ADF_LOG_DIR" "$ADF_GEO_DIR"

UNW_TAG="${UNW_ENGINE}"
# Include mk_unw_2d parameters in output tags so different tests do not overwrite each other.
if [[ "$UNW_ENGINE" == "mk_unw_2d" ]]; then
  UNW_TAG="mk_unw_2d_cc${MKUNW_CC_THRES//./p}_nlks${MKUNW_NLKS}_patch${MKUNW_NPAT_R}x${MKUNW_NPAT_AZ}_mode${MKUNW_MODE}"
elif [[ "$UNW_ENGINE" == "mk_unw_2d_branch_cut" ]]; then
  UNW_TAG="mk_unw_2d_branchcut_buf${BRANCH_BUFFER_KM//./p}km_cc${MKUNW_CC_THRES//./p}_nlks${MKUNW_NLKS}_patch${MKUNW_NPAT_R}x${MKUNW_NPAT_AZ}_mode${MKUNW_MODE}"
fi

DIFF0_ADF="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}"
DIFF0_ADF_CC="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.cc"
DIFF0_ADF_PHASE="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.phase"
DIFF0_ADF_UNW="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.unw"
DIFF0_ADF_UNW_NATIVE="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.unw.native"
DIFF0_ADF_UNW_RAW="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.unw.raw"
DIFF0_ADF_LOS_M="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.los_m"
DIFF0_ADF_LOS_M_RAW="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.los_m.raw"
DIFF0_ADF_UNW_MASK="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.valid_mask.uint8"
SNAPHU_QC="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.qc.txt"
SNAPHU_PHASE_NATIVE="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.phase.native"
SNAPHU_CC_NATIVE="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.cc.snaphu.native"
SNAPHU_CONF="${ADF_DIR}/${PAIR}_${LOOK}.snaphu.conf"
MKUNW_DIR="${ADF_DIR}/${UNW_TAG}"
MKUNW_DIFF_DIR="${MKUNW_DIR}/diff"
MKUNW_RSLC_TAB="${MKUNW_DIR}/${PAIR}_${LOOK}.RSLC_tab"
MKUNW_ITAB="${MKUNW_DIR}/${PAIR}_${LOOK}.itab"
MKUNW_LOG="${ADF_LOG_DIR}/mk_unw_2d.log"
MKUNW_OUT_LIST="${MKUNW_DIR}/mk_unw_2d_outputs.txt"
NS_MASK_DIR="${MKUNW_DIR}/ns_masks"
NS_MAP_NORTH="${NS_MASK_DIR}/north.map"
NS_MAP_SOUTH="${NS_MASK_DIR}/south.map"
NS_MAP_GAP="${NS_MASK_DIR}/gap.map"
NS_MAP_NORTH_REF="${NS_MASK_DIR}/north_ref.map"
NS_MAP_SOUTH_REF="${NS_MASK_DIR}/south_ref.map"
NS_RDC_NORTH="${NS_MASK_DIR}/north.rdc"
NS_RDC_SOUTH="${NS_MASK_DIR}/south.rdc"
NS_RDC_GAP="${NS_MASK_DIR}/gap.rdc"
NS_RDC_NORTH_REF="${NS_MASK_DIR}/north_ref.rdc"
NS_RDC_SOUTH_REF="${NS_MASK_DIR}/south_ref.rdc"
NS_RDC_NORTH_VALID="${NS_MASK_DIR}/north_valid.rdc"
NS_RDC_SOUTH_VALID="${NS_MASK_DIR}/south_valid.rdc"
NS_BMP_NORTH="${NS_MASK_DIR}/north_mask.bmp"
NS_BMP_SOUTH="${NS_MASK_DIR}/south_mask.bmp"
NS_SPLIT_QC="${MKUNW_DIR}/ns_split_qc.txt"
NS_COMBINED_RAW_NATIVE="${ADF_DIR}/${PAIR}_${LOOK}.diff0.${ADF_TAG}.${UNW_TAG}.unw.raw_native"

if [[ "$PLOT_CROP_TO_ROI" -eq 1 ]]; then PLOT_SCOPE_TAG="roi"; else PLOT_SCOPE_TAG="full"; fi
PLOT_TAG="cc${cc_tag}_unwcc${unwcc_tag}_water${MASK_WATER}_${PLOT_SCOPE_TAG}"
PLOT_DIR="${ADF_DIR}/plots_${PLOT_TAG}"
GRD_TAG="roi${GRD_CROP_TO_ROI}_cohmask${GRD_APPLY_COH_MASK}_cc$(python3 - <<PY
print(f"{int(round(float('${GRD_COH_THRESHOLD}')*100)):02d}")
PY
)_water${GRD_APPLY_WATER_MASK}_unw${UNW_TAG}_losref${GRD_LOS_REF_MODE}"
GRD_DIR="${ADF_DIR}/grd_${GRD_TAG}"
mkdir -p "$PLOT_DIR" "$GRD_DIR"

log(){ echo "[$(date '+%F %T')] $*"; }
need_file(){ [[ -f "$1" ]] || { echo "ERROR: missing file: $1" >&2; exit 1; }; }
need_nonempty(){ [[ -s "$1" ]] || { echo "ERROR: missing or empty file: $1" >&2; exit 1; }; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: command not found: $1" >&2; exit 1; }; }

is_bool01(){ [[ "$1" == "0" || "$1" == "1" ]]; }

validate_release_configuration(){
  [[ "$REF" =~ ^[0-9]{8}$ ]] || { echo "[ERROR] REF must be YYYYMMDD: $REF" >&2; exit 2; }
  [[ "$SEC" =~ ^[0-9]{8}$ ]] || { echo "[ERROR] SEC must be YYYYMMDD: $SEC" >&2; exit 2; }
  [[ "$REF" != "$SEC" ]] || { echo "[ERROR] REF and SEC must differ" >&2; exit 2; }
  case "${POL,,}" in vv|vh|hh|hv) ;; *) echo "[ERROR] unsupported POL=$POL" >&2; exit 2 ;; esac
  case "$UNW_ENGINE" in none|snaphu|gamma_mcf|mk_unw_2d|mk_unw_2d_branch_cut) ;; *) echo "[ERROR] unknown UNW_ENGINE=$UNW_ENGINE" >&2; exit 2 ;; esac
  case "$GRD_LOS_REF_MODE" in none|output_median|global|box) ;; *) echo "[ERROR] invalid GRD_LOS_REF_MODE=$GRD_LOS_REF_MODE" >&2; exit 2 ;; esac
  case "$UNW_REF_MODE" in none|global) ;; *) echo "[ERROR] invalid UNW_REF_MODE=$UNW_REF_MODE" >&2; exit 2 ;; esac
  local b
  for b in "$DO_UNWRAP" "$DO_WRITE_GRD" "$GRD_CROP_TO_ROI" "$PLOT_CROP_TO_ROI" "$MARKER_ON" \
           "$QC_ENABLE" "$AUTO_COMPAT_MODE" "$GEOCODE_EDGE_QC" "$GEOCODE_FAIL_ON_DEM_EDGE_CLIP"; do
    is_bool01 "$b" || { echo "[ERROR] expected a 0/1 switch, got: $b" >&2; exit 2; }
  done
  (( RLKS > 0 && ALKS > 0 && COREG_RLKS > 0 && COREG_ALKS > 0 )) || { echo "[ERROR] look factors must be positive integers" >&2; exit 2; }

  if [[ -f "$PREPARED_INPUTS_FILE" && "$ALLOW_PREPARED_MISMATCH" -ne 1 ]]; then
    [[ -z "$PREP_REF" || "$PREP_REF" == "$REF" ]] || { echo "[ERROR] REF=$REF conflicts with prepared REF=$PREP_REF in $PREPARED_INPUTS_FILE" >&2; exit 2; }
    [[ -z "$PREP_SEC" || "$PREP_SEC" == "$SEC" ]] || { echo "[ERROR] SEC=$SEC conflicts with prepared SEC=$PREP_SEC in $PREPARED_INPUTS_FILE" >&2; exit 2; }
    [[ -z "$PREP_POL" || "${PREP_POL,,}" == "${POL,,}" ]] || { echo "[ERROR] POL=$POL conflicts with prepared POL=$PREP_POL" >&2; exit 2; }
  fi

  if [[ "$UNW_ENGINE" == "mk_unw_2d_branch_cut" && "$DO_UNWRAP" -eq 1 ]]; then
    python3 - <<PY_BOX
vals=[float('$NORTH_REF_LON_MIN'),float('$NORTH_REF_LON_MAX'),float('$NORTH_REF_LAT_MIN'),float('$NORTH_REF_LAT_MAX'),
      float('$SOUTH_REF_LON_MIN'),float('$SOUTH_REF_LON_MAX'),float('$SOUTH_REF_LAT_MIN'),float('$SOUTH_REF_LAT_MAX')]
if not (vals[0] < vals[1] and vals[2] < vals[3] and vals[4] < vals[5] and vals[6] < vals[7]):
    raise SystemExit('branch-cut mode requires valid north/south reference boxes')
PY_BOX
  fi
}

preflight_dependencies(){
  local missing=0 cmd
  local required=(python3 S1_coreg_TOPS SLC_mosaic_S1_TOPS base_orbit multi_look create_offset init_offset_orbit SLC_intf cc_wave gc_map pixel_area offset_pwrm offset_fitm gc_map_fine geocode phase_sim sub_phase adf geocode_back)
  if [[ "$COREG_BURST_SELECT_USED" == "manual_count" || "$AUTO_COMPAT_MODE" -eq 1 ]]; then required+=(SLC_copy_S1_TOPS); fi
  if [[ "$DO_UNWRAP" -eq 1 ]]; then
    case "$UNW_ENGINE" in
      snaphu) required+=(snaphu) ;;
      gamma_mcf) required+=(rascc_mask mcf) ;;
      mk_unw_2d|mk_unw_2d_branch_cut) required+=(mk_unw_2d) ;;
    esac
  fi
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then echo "[ERROR] required command not found: $cmd" >&2; missing=1; fi
  done
  python3 - <<PY_MOD || missing=1
import importlib
mods=['numpy','matplotlib']
if int('$DO_WRITE_GRD') == 1:
    mods.append('osgeo')
missing=[]
for m in mods:
    try: importlib.import_module(m)
    except Exception as e: missing.append(f'{m}: {e}')
if missing:
    raise SystemExit('missing Python modules: ' + '; '.join(missing))
PY_MOD
  (( missing == 0 )) || exit 2
}

export_release_configuration(){
  export PROJECT_ROOT PREPARED_INPUTS_FILE REF SEC POL REF_TAB SEC_TAB DEM DEM_PAR
  export ROI_LON_MIN ROI_LON_MAX ROI_LAT_MIN ROI_LAT_MAX MARKER_ON MARKER_LON MARKER_LAT
  export FORCE_COREG FORCE_MOSAIC FORCE_LOOK FORCE_ADF FORCE_SNAPHU FORCE_PLOT FORCE_GRD
  export RLKS ALKS ADF_ALPHA ADF_NFFT ADF_CCWIN DO_UNWRAP UNW_ENGINE UNW_COH_THRESHOLD
  export BRANCH_CUT_FILE BRANCH_BUFFER_KM BRANCH_ORIENT_BY_REF_BOX
  export NORTH_REF_LON_MIN NORTH_REF_LON_MAX NORTH_REF_LAT_MIN NORTH_REF_LAT_MAX
  export SOUTH_REF_LON_MIN SOUTH_REF_LON_MAX SOUTH_REF_LAT_MIN SOUTH_REF_LAT_MAX
  export DO_WRITE_GRD GRD_CROP_TO_ROI GRD_APPLY_COH_MASK GRD_COH_THRESHOLD
  export GRD_APPLY_WATER_MASK GRD_WATER_DEM_THRESHOLD GRD_LOS_REF_MODE
  export GRD_LOS_REF_LON_MIN GRD_LOS_REF_LON_MAX GRD_LOS_REF_LAT_MIN GRD_LOS_REF_LAT_MAX
  export COREG_RLKS COREG_ALKS COREG_ENGINE COREG_HGT COREG_CC_THRESH COREG_FRACTION_THRESH
  export COREG_PH_STDEV_THRESH COREG_CLEANING COREG_USE_EXISTING SWATHS_TO_PROCESS
  export MOSAIC_SOURCE_MODE SLC_INTF_MAX_AZ_LINE_MISMATCH REPAIR_ZERO_RSLCPAR REPAIR_SOURCE COREG_STRICT_CLEAN
  export COREG_ORDER COREG_BURST_SELECT COREG_BURST_STRATEGY OUTPUT_SIGN_MODE COREG_BURST_KEEP_FAILED_TRIALS
  export SPS_FLG AZF_FLG RP1_FLG RP2_FLG AZ_BETA AUTO_COMPAT_MODE QC_ENABLE QC_ENFORCE
  export QC_MIN_SWATH_NONZERO QC_MIN_SWATH_MEAN QC_MIN_SWATH_P75 QC_ZERO_EPS
  export SNAPHU_COST_MODE SNAPHU_INIT_METHOD SNAPHU_NCORRLOOKS SNAPHU_EXTRA_OPTS WAVELENGTH_M LOS_SIGN SNAPHU_CORR_FLOOR
  export UNW_REF_MODE UNW_REF_COH_THRESHOLD UNW_REMOVE_PLANE UNW_OUTPUT_APPLY_MASK
  export UNW_OUTPUT_COH_THRESHOLD UNW_OUTPUT_WATER_MASK UNW_OUTPUT_WATER_THRESHOLD
  export MKUNW_CC_THRES MKUNW_PWR_THRES MKUNW_NLKS MKUNW_NPAT_R MKUNW_NPAT_AZ MKUNW_MODE
  export MKUNW_R_INIT MKUNW_AZ_INIT MKUNW_TRI_MODE MKUNW_MASK MKUNW_ROFF MKUNW_LOFF MKUNW_NR MKUNW_NLINES
  export NS_REF_COH_THRESHOLD NS_MASK_WATER NS_MIN_REF_PIXELS NS_MIN_REGION_PIXELS
  export PLOT_CROP_TO_ROI PLOT_COH_THRESHOLD MASK_WATER WATER_DEM_THRESHOLD REMOVE_RAMP RAMP_FIT_COH_THRESHOLD
  export LAT_OVR LON_OVR GEO_OFF_WIN_R GEO_OFF_WIN_A GEO_OFF_OVR GEO_OFF_NR GEO_OFF_NAZ GEO_OFF_CC_THR GEO_FIT_CC_THR GEO_FIT_NPAR GEOCODE_UNW_INTERP
  export GEOCODE_EDGE_QC GEOCODE_FAIL_ON_DEM_EDGE_CLIP GEOCODE_EDGE_BAND_PIXELS GEOCODE_EDGE_VALID_FRACTION GEOCODE_EDGE_CC_EPS
  export GRD_DRIVER GRD_WRITE_NAN_LOS_IF_NO_UNW GRD_LOS_REF_COH_THRESHOLD GRD_LOS_REF_WATER_MASK GRD_LOS_REF_WATER_THRESHOLD GRD_WRITE_RAW_LOS
  export ALLOW_PREPARED_MISMATCH PUBLISH_FINAL
}

print_resolved_configuration(){
  cat <<TXT
S1_gamma_process release ${SCRIPT_VERSION}
PROJECT_ROOT=$PROJECT_ROOT
PREPARED_INPUTS_FILE=$PREPARED_INPUTS_FILE
PAIR=$PAIR
REF_TAB=$REF_TAB
SEC_TAB=$SEC_TAB
DEM=$DEM
DEM_PAR=$DEM_PAR
SWATHS_TO_PROCESS=$SWATHS_TO_PROCESS
MOSAIC_SOURCE_MODE=$MOSAIC_SOURCE_MODE -> $MOSAIC_SOURCE_MODE_RESOLVED
SPS_FLG=$SPS_FLG -> $SPS_FLG_USED
AZF_FLG=$AZF_FLG -> $AZF_FLG_USED
DO_UNWRAP=$DO_UNWRAP
UNW_ENGINE=$UNW_ENGINE
PLOT_CROP_TO_ROI=$PLOT_CROP_TO_ROI
GRD_CROP_TO_ROI=$GRD_CROP_TO_ROI
FORCE_COREG=$FORCE_COREG FORCE_MOSAIC=$FORCE_MOSAIC FORCE_LOOK=$FORCE_LOOK FORCE_ADF=$FORCE_ADF FORCE_SNAPHU=$FORCE_SNAPHU FORCE_PLOT=$FORCE_PLOT FORCE_GRD=$FORCE_GRD
TXT
}

validate_slc_tab_metadata(){
  local tab="$1" label="$2" bad=0 slc par tops rest
  while read -r slc par tops rest; do
    [[ -z "${slc:-}" ]] && continue
    [[ "${slc:0:1}" == "#" ]] && continue
    if [[ ! -s "$slc" || ! -s "$par" || ! -s "$tops" ]]; then
      echo "ERROR: $label tab points to missing/empty GAMMA input:" >&2
      echo "  SLC=$slc" >&2
      echo "  PAR=$par" >&2
      echo "  TOPS=$tops" >&2
      bad=1
      continue
    fi
    for key in range_samples azimuth_lines radar_frequency prf azimuth_line_time; do
      if ! grep -q "^${key}:" "$par"; then
        echo "ERROR: $label SLC_par lacks required keyword '$key': $par" >&2
        bad=1
      fi
    done
  done < "$tab"
  [[ "$bad" -eq 0 ]] || {
    echo "ERROR: Prepared SLC_tab metadata are incomplete. Re-run S1_gamma_prepare.sh or inspect S1_import logs before S1_coreg_TOPS." >&2
    exit 1
  }
}

check_inputs(){
  need_file "$REF_TAB"
  need_file "$SEC_TAB"
  need_file "$COREG_REF_TAB_SRC"
  need_file "$COREG_SEC_TAB_SRC"
  need_file "$DEM"
  need_file "$DEM_PAR"
  validate_slc_tab_metadata "$REF_TAB" science_reference
  validate_slc_tab_metadata "$SEC_TAB" science_secondary
  validate_slc_tab_metadata "$COREG_REF_TAB_SRC" coreg_reference
  validate_slc_tab_metadata "$COREG_SEC_TAB_SRC" coreg_secondary
}

extract_iw(){
  local base iw
  base=$(basename "$1")
  iw=$(echo "$base" | grep -oiE 'iw[0-9]' | head -1 || true)
  echo "${iw,,}"
}

swath_is_selected(){
  local iw="${1,,}"
  local sel="${SWATHS_TO_PROCESS,,}"
  sel=$(echo "$sel" | tr -d ' ')
  [[ "$sel" == "all" ]] && return 0
  IFS=',' read -ra arr <<< "$sel"
  local x
  for x in "${arr[@]}"; do
    [[ "$x" == "$iw" ]] && return 0
  done
  return 1
}

filter_tab_by_swath(){
  local in_tab="$1" out_tab="$2" label="$3"
  : > "$out_tab"
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" ]] && continue
    [[ "${slc:0:1}" == "#" ]] && continue
    local iw
    iw=$(extract_iw "$slc")
    if [[ -z "$iw" ]]; then
      echo "WARNING: cannot infer IW swath from $slc; keeping it in $label tab" >&2
      printf "%s %s %s\n" "$slc" "$par" "$tops" >> "$out_tab"
    elif swath_is_selected "$iw"; then
      printf "%s %s %s\n" "$slc" "$par" "$tops" >> "$out_tab"
    fi
  done < "$in_tab"
  if [[ ! -s "$out_tab" ]]; then
    echo "ERROR: $label tab is empty after SWATHS_TO_PROCESS=$SWATHS_TO_PROCESS" >&2
    echo "Input tab was: $in_tab" >&2
    cat "$in_tab" >&2 || true
    exit 1
  fi
}

tab_data_row_count(){
  awk 'NF>=3 && $1 !~ /^#/ {n++} END{print n+0}' "$1"
}

validate_all_swath_tabs(){
  [[ "${SWATHS_TO_PROCESS,,}" == "all" ]] || return 0
  local nr ns
  nr=$(tab_data_row_count "$COREG_REF_TAB_SRC")
  ns=$(tab_data_row_count "$COREG_SEC_TAB_SRC")
  if (( nr < 3 || ns < 3 )); then
    echo "[ERROR] SWATHS_TO_PROCESS=all requires three IW rows in both prepared tabs." >&2
    echo "        reference rows=${nr}: $COREG_REF_TAB_SRC" >&2
    echo "        secondary rows=${ns}: $COREG_SEC_TAB_SRC" >&2
    echo "        Re-run prepare/import and verify IW1/IW2/IW3 are all present." >&2
    exit 1
  fi
}

copy_tabs(){
  validate_all_swath_tabs
  filter_tab_by_swath "$COREG_REF_TAB_SRC" "$REF_TAB_LOCAL" coreg_reference
  filter_tab_by_swath "$COREG_SEC_TAB_SRC" "$SEC_TAB_LOCAL" coreg_secondary
  SEC_TAB_FOR_COREG="$SEC_TAB_LOCAL"
  log "Selected swath(s): $SWATHS_TO_PROCESS"
  log "Coreg cache: $COREG_DIR"
  log "Science pair: ${REF}_${SEC}; internal coreg pair: ${COREG_REF}_${COREG_SEC}; output phase sign: ${OUTPUT_PHASE_SIGN}"
  log "Reference tab: $REF_TAB_LOCAL"
  cat "$REF_TAB_LOCAL"
  log "Secondary tab: $SEC_TAB_LOCAL"
  cat "$SEC_TAB_LOCAL"
}

make_rslc_tab(){
  local out_tab="$SEC_RSLC_TAB_LOCAL"
  : > "$out_tab"
  local idx=1
  while read -r slc par tops; do
    [[ -z "${slc:-}" ]] && continue
    [[ "${slc:0:1}" == "#" ]] && continue
    local base iw out_slc out_par out_tops
    base=$(basename "$slc")
    iw=$(echo "$base" | grep -oiE 'iw[0-9]' | head -1 || true)
    if [[ -z "$iw" ]]; then
      iw="iw${idx}"
    else
      iw=$(echo "$iw" | tr 'A-Z' 'a-z')
    fi
    out_slc="${COREG_SEC}_${iw}_${POL}.rslc"
    out_par="${COREG_SEC}_${iw}_${POL}.rslc.par"
    out_tops="${COREG_SEC}_${iw}_${POL}.rslc.tops_par"
    printf "%s %s %s\n" "$out_slc" "$out_par" "$out_tops" >> "$out_tab"
    idx=$((idx+1))
  done < "$SEC_TAB_FOR_COREG"
  [[ -s "$out_tab" ]] || { echo "ERROR: failed to create non-empty RSLC tab: $out_tab" >&2; exit 1; }
}

rslc_tab_all_outputs_exist(){
  local tab="$1"
  local ok=0
  while read -r rslc rpar rtops; do
    [[ -z "${rslc:-}" ]] && continue
    if [[ ! -s "$COREG_DIR/$rslc" || ! -s "$COREG_DIR/$rpar" || ! -s "$COREG_DIR/$rtops" ]]; then
      return 1
    fi
    ok=1
  done < "$tab"
  [[ "$ok" -eq 1 ]]
}

lookup_source_metadata_for_iw(){
  local iw="$1" source="$2" slc par tops
  local tab="$SEC_TAB_FOR_COREG"
  [[ "$source" == "reference" ]] && tab="$REF_TAB_LOCAL"
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" ]] && continue
    [[ "${slc:0:1}" == "#" ]] && continue
    if [[ "$(extract_iw "$slc")" == "$iw" ]]; then
      printf "%s %s\n" "$par" "$tops"
      return 0
    fi
  done < "$tab"
  return 1
}

repair_zero_rslc_metadata(){
  [[ "$REPAIR_ZERO_RSLCPAR" -eq 1 ]] || return 0
  local changed=0
  while read -r rslc rpar rtops; do
    [[ -z "${rslc:-}" ]] && continue
    local iw src_par src_tops
    iw=$(extract_iw "$rslc")
    if [[ -s "$COREG_DIR/$rslc" && ( ! -s "$COREG_DIR/$rpar" || ! -s "$COREG_DIR/$rtops" ) ]]; then
      read -r src_par src_tops < <(lookup_source_metadata_for_iw "$iw" "$REPAIR_SOURCE" || true)
      if [[ -n "${src_par:-}" && -s "$src_par" && -n "${src_tops:-}" && -s "$src_tops" ]]; then
        echo "WARNING: repairing zero/missing metadata for $rslc using $REPAIR_SOURCE metadata of $iw" >&2
        cp "$src_par" "$COREG_DIR/$rpar"
        cp "$src_tops" "$COREG_DIR/$rtops"
        changed=1
      else
        echo "WARNING: cannot repair metadata for $rslc; no source metadata found for $iw from $REPAIR_SOURCE" >&2
      fi
    fi
  done < "$SEC_RSLC_TAB_LOCAL"
  [[ "$changed" -eq 1 ]] && echo "WARNING: Metadata repair was applied. Treat results as diagnostic/visual until verified." >&2
}

print_coreg_tail(){
  echo "---- tail of S1_coreg_TOPS.log ----" >&2
  tail -100 "${COREG_LOG_DIR}/S1_coreg_TOPS.log" >&2 || true
  echo "-----------------------------------" >&2
}

slc_copy_dtype_from_tab(){
  local tab="$1" par fmt
  par=$(awk 'NF>=2 && $1 !~ /^#/ {print $2; exit}' "$tab" 2>/dev/null || true)
  fmt=$(awk '$1=="image_format:"{print $2; exit}' "$par" 2>/dev/null || true)
  case "$fmt" in
    FCOMPLEX) echo 0 ;;
    SCOMPLEX) echo 1 ;;
    *) echo "" ;;
  esac
}

n_bursts_from_tops(){
  awk '$1=="number_of_bursts:" {print int($2); exit}' "$1" 2>/dev/null || echo 0
}

find_ref_tops_for_iw(){
  local iw="$1" slc par tops extra
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" || "${slc:0:1}" == "#" ]] && continue
    if [[ "$(extract_iw "$slc")" == "$iw" ]]; then
      echo "$tops"
      return 0
    fi
  done < "$REF_TAB_LOCAL"
  return 1
}

build_time_aligned_burst_tab(){
  local out="$1"
  # Choose a separate secondary burst-window offset for each IW.  The selected
  # secondary first-burst time should differ from the reference first-burst time
  # by one common satellite-to-satellite timing offset across IW1/IW2/IW3.
  # This handles the observed S1A-S1C case where IW1/IW2 require the last N
  # bursts while IW3 requires the first N bursts.
  REF_TAB_LOCAL="$REF_TAB_LOCAL" SEC_TAB_LOCAL="$SEC_TAB_LOCAL" OUT_BURST_TAB="$out" python3 - <<'PY_TIME_ALIGN'
import itertools, math, os, re, sys

ref_tab=os.environ['REF_TAB_LOCAL']
sec_tab=os.environ['SEC_TAB_LOCAL']
out=os.environ['OUT_BURST_TAB']

def rows(path):
    ans=[]
    with open(path, errors='ignore') as f:
        for ln in f:
            p=ln.split()
            if len(p)<3 or ln.lstrip().startswith('#'):
                continue
            base=os.path.basename(p[0]).lower()
            m=re.search(r'iw[123]',base)
            iw=m.group(0) if m else f'iw{len(ans)+1}'
            ans.append((iw,p[0],p[1],p[2]))
    return ans

def tops(path):
    d={}
    with open(path, errors='ignore') as f:
        for ln in f:
            p=ln.replace(':',' ').split()
            if len(p)>=2:
                try: d[p[0]]=float(p[1])
                except ValueError: pass
    return d

def daywrap(x):
    return (x+43200.0)%86400.0-43200.0

rref={r[0]:r for r in rows(ref_tab)}
rsec=rows(sec_tab)
items=[]
for iw,slc,par,tp in rsec:
    if iw not in rref:
        raise RuntimeError(f'no reference row for {iw}')
    rt=tops(rref[iw][3]); st=tops(tp)
    nr=int(rt.get('number_of_bursts',0)); ns=int(st.get('number_of_bursts',0))
    tr=rt.get('burst_start_time_1'); ts=st.get('burst_start_time_1')
    dt=st.get('burst_interval',rt.get('burst_interval'))
    if nr<=0 or ns<nr or tr is None or ts is None or not dt:
        raise RuntimeError(f'invalid TOPS metadata for {iw}: ref={nr} sec={ns} tr={tr} ts={ts} dt={dt}')
    maxoff=ns-nr
    items.append(dict(iw=iw,nr=nr,ns=ns,base=daywrap(ts-tr),dt=float(dt),offsets=range(maxoff+1)))

# Brute force is tiny for three IW swaths. Minimize inter-swath timing spread,
# then MAD, then total offset as a deterministic tie-break.
best=None
for offs in itertools.product(*(x['offsets'] for x in items)):
    vals=[x['base']+o*x['dt'] for x,o in zip(items,offs)]
    med=float(sorted(vals)[len(vals)//2])
    spread=max(vals)-min(vals) if vals else math.inf
    mad=sum(abs(v-med) for v in vals)/max(1,len(vals))
    obj=(spread,mad,sum(offs),offs)
    if best is None or obj<best[0]:
        best=(obj,offs,vals)
if best is None:
    raise RuntimeError('no time-alignment burst-window solution')
_,offs,vals=best
with open(out,'w') as f:
    for x,o,v in zip(items,offs,vals):
        start=o+1; end=o+x['nr']
        f.write(f'{start} {end}\n')
        print(f'[try][time_align] {x["iw"]} ref_bursts={x["nr"]} sec_bursts={x["ns"]} '
              f'base_dt={x["base"]:.6f}s offset={o} keep={start}-{end} selected_dt={v:.6f}s')
print(f'[try][time_align] selected timing spread={best[0][0]:.6f}s MAD={best[0][1]:.6f}s')
PY_TIME_ALIGN
}

build_manual_burst_tab(){
  local strategy="$1" out="$2" slc par tops extra iw ref_tops n_ref n_sec start end
  : > "$out"
  if [[ "$strategy" == "time_align" || "$strategy" == "timing" || "$strategy" == "per_iw" ]]; then
    build_time_aligned_burst_tab "$out"
    return $?
  fi
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" || "${slc:0:1}" == "#" ]] && continue
    iw=$(extract_iw "$slc")
    ref_tops=$(find_ref_tops_for_iw "$iw" || true)
    if [[ -z "${ref_tops:-}" || ! -s "$ref_tops" ]]; then
      echo "[try][$strategy] cannot find matching reference TOPS_par for $iw" >> "${COREG_LOG_DIR}/burst_selection.${strategy}.log"
      return 1
    fi
    n_ref=$(n_bursts_from_tops "$ref_tops")
    n_sec=$(n_bursts_from_tops "$tops")
    if (( n_ref <= 0 || n_sec <= 0 || n_sec < n_ref )); then
      echo "[try][$strategy] invalid burst counts for $iw: ref=$n_ref sec=$n_sec" >> "${COREG_LOG_DIR}/burst_selection.${strategy}.log"
      return 1
    fi
    case "$strategy" in
      first9|first|head)
        start=1; end=$n_ref ;;
      last9|last|tail)
        start=$((n_sec - n_ref + 1)); end=$n_sec ;;
      *)
        echo "[try][$strategy] unknown manual burst-selection strategy" >> "${COREG_LOG_DIR}/burst_selection.${strategy}.log"
        return 1 ;;
    esac
    printf "%d %d\n" "$start" "$end" >> "$out"
    echo "[try][$strategy] $iw ref_bursts=$n_ref sec_bursts=$n_sec keep=${start}-${end}" >> "${COREG_LOG_DIR}/burst_selection.${strategy}.log"
  done < "$SEC_TAB_LOCAL"
  [[ -s "$out" ]]
}

make_selected_sec_tab_paths(){
  local strategy="$1" out="$2" slc par tops extra iw dir
  dir="${COREG_DIR}/burst_select_${strategy}"
  mkdir -p "$dir"
  : > "$out"
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" || "${slc:0:1}" == "#" ]] && continue
    iw=$(extract_iw "$slc")
    printf "%s/%s.%s.selected.%s.slc %s/%s.%s.selected.%s.slc.par %s/%s.%s.selected.%s.slc.TOPS_par\n" \
      "$dir" "$COREG_SEC" "$POL" "$iw" \
      "$dir" "$COREG_SEC" "$POL" "$iw" \
      "$dir" "$COREG_SEC" "$POL" "$iw" >> "$out"
  done < "$SEC_TAB_LOCAL"
  [[ -s "$out" ]]
}

validate_selected_sec_tab(){
  local tab="$1" slc par tops extra n=0
  while read -r slc par tops extra; do
    [[ -z "${slc:-}" || "${slc:0:1}" == "#" ]] && continue
    if [[ ! -s "$slc" || ! -s "$par" || ! -s "$tops" ]]; then
      return 1
    fi
    n=$((n+1))
  done < "$tab"
  [[ "$n" -gt 0 ]]
}

try_manual_burst_selection(){
  local strategy="$1" dtype burst_tab selected_tab try_log status
  try_log="${COREG_LOG_DIR}/burst_selection.${strategy}.log"
  : > "$try_log"
  dtype=$(slc_copy_dtype_from_tab "$SEC_TAB_LOCAL")
  if [[ -z "$dtype" ]]; then
    echo "[try][$strategy] cannot infer image_format/dtype from $SEC_TAB_LOCAL" >> "$try_log"
    return 1
  fi
  burst_tab="${COREG_DIR}/manual_${strategy}.BURST_tab"
  selected_tab="${COREG_DIR}/${COREG_SEC}_${POL}.selected.${strategy}.SLC_tab"
  rm -rf "${COREG_DIR}/burst_select_${strategy}" "$selected_tab" "$burst_tab" 2>/dev/null || true
  make_selected_sec_tab_paths "$strategy" "$selected_tab" >> "$try_log" 2>&1 || return 1
  build_manual_burst_tab "$strategy" "$burst_tab" >> "$try_log" 2>&1 || return 1
  echo "[try][$strategy] SLC_copy_S1_TOPS dtype=$dtype" >> "$try_log"
  set +e
  (
    cd "$COREG_DIR"
    SLC_copy_S1_TOPS "$SEC_TAB_LOCAL" "$selected_tab" "$burst_tab" "$dtype"
  ) >> "$try_log" 2>&1
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "[try][$strategy] SLC_copy_S1_TOPS returned status $status" >> "$try_log"
    return 1
  fi
  if ! validate_selected_sec_tab "$selected_tab"; then
    echo "[try][$strategy] selected secondary tab has missing outputs" >> "$try_log"
    return 1
  fi
  SEC_TAB_FOR_COREG="$selected_tab"
  echo "[try][$strategy] selected secondary tab: $selected_tab" >> "$try_log"
  return 0
}

prepare_secondary_tab_for_coreg(){
  SEC_TAB_FOR_COREG="$SEC_TAB_LOCAL"
  [[ "$COREG_BURST_SELECT_USED" == "manual_count" ]] || return 0
  need_cmd SLC_copy_S1_TOPS
  local strategies=()
  case "$COREG_BURST_STRATEGY" in
    auto)
      strategies=(time_align last9 first9) ;;
    time_align|timing|per_iw|last9|first9)
      strategies=("$COREG_BURST_STRATEGY") ;;
    *)
      echo "[ERROR] unknown COREG_BURST_STRATEGY=${COREG_BURST_STRATEGY}; use auto/time_align/last9/first9" >&2
      exit 1 ;;
  esac
  local st
  for st in "${strategies[@]}"; do
    log "Burst harmonization trial: strategy=${st}"
    if try_manual_burst_selection "$st"; then
      COREG_BURST_STRATEGY_USED="$st"
      log "Burst harmonization accepted: strategy=${st}; secondary tab=${SEC_TAB_FOR_COREG}"
      return 0
    else
      log "Burst harmonization trial did not pass: strategy=${st}; see ${COREG_LOG_DIR}/burst_selection.${st}.log"
    fi
  done
  echo "[ERROR] All manual burst-selection strategies failed." >&2
  echo "[ERROR] Inspect: ${COREG_LOG_DIR}/burst_selection.*.log" >&2
  exit 1
}

coregister_tops(){
  if [[ "$FORCE_COREG" -eq 1 ]]; then
    rm -f "$SEC_RSLC_TAB_LOCAL" "${SEC_RSLC_TAB_LOCAL}.coreg_done"
    rm -f "${COREG_DIR}/${COREG_SEC}_iw"*"_${POL}.rslc" "${COREG_DIR}/${COREG_SEC}_iw"*"_${POL}.rslc.par" "${COREG_DIR}/${COREG_SEC}_iw"*"_${POL}.rslc.tops_par" 2>/dev/null || true
    rm -f "${COREG_DIR}/${COREG_PAIR}.diff" "${COREG_DIR}/${COREG_PAIR}.diff.bmp" "${COREG_DIR}/${COREG_PAIR}.coreg_quality" 2>/dev/null || true
    rm -f "$REF_MOSAIC" "$REF_MOSAIC_PAR" "$SEC_MOSAIC" "$SEC_MOSAIC_PAR" "$BASE" 2>/dev/null || true
  fi

  copy_tabs
  prepare_secondary_tab_for_coreg

  if [[ -f "${SEC_RSLC_TAB_LOCAL}.coreg_done" && -f "$SEC_RSLC_TAB_LOCAL" ]] && rslc_tab_all_outputs_exist "$SEC_RSLC_TAB_LOCAL"; then
    log "Reuse TOPS coregistration: $SEC_RSLC_TAB_LOCAL"
    return 0
  fi

  case "$COREG_ENGINE" in
    none)
      need_file "$SEC_RSLC_TAB_LOCAL"
      ;;
    auto)
      need_cmd S1_coreg_TOPS
      make_rslc_tab
      log "TOPS coregistration with S1_coreg_TOPS v1.5-style syntax, coreg looks=${COREG_LOOK}"
      {
        echo "PWD=$COREG_DIR"
        echo "REF_TAB_LOCAL=$REF_TAB_LOCAL"
        cat "$REF_TAB_LOCAL"
        echo "SEC_TAB_LOCAL=$SEC_TAB_LOCAL"
        cat "$SEC_TAB_LOCAL"
        echo "SEC_TAB_FOR_COREG=$SEC_TAB_FOR_COREG"
        cat "$SEC_TAB_FOR_COREG"
        echo "SEC_RSLC_TAB_LOCAL=$SEC_RSLC_TAB_LOCAL"
        cat "$SEC_RSLC_TAB_LOCAL"
        echo "Command: cd $COREG_DIR && S1_coreg_TOPS $(basename "$REF_TAB_LOCAL") $COREG_REF $(basename "$SEC_TAB_FOR_COREG") $COREG_SEC $(basename "$SEC_RSLC_TAB_LOCAL") $COREG_HGT $COREG_RLKS $COREG_ALKS - - $COREG_CC_THRESH $COREG_FRACTION_THRESH $COREG_PH_STDEV_THRESH $COREG_CLEANING $COREG_USE_EXISTING"
      } > "${COREG_LOG_DIR}/S1_coreg_TOPS.inputs.log"

      set +e
      (
        cd "$COREG_DIR"
        S1_coreg_TOPS "$(basename "$REF_TAB_LOCAL")" "$COREG_REF" "$(basename "$SEC_TAB_FOR_COREG")" "$COREG_SEC" "$(basename "$SEC_RSLC_TAB_LOCAL")" \
          "$COREG_HGT" "$COREG_RLKS" "$COREG_ALKS" - - \
          "$COREG_CC_THRESH" "$COREG_FRACTION_THRESH" "$COREG_PH_STDEV_THRESH" \
          "$COREG_CLEANING" "$COREG_USE_EXISTING"
      ) > "${COREG_LOG_DIR}/S1_coreg_TOPS.log" 2>&1
      local status=$?
      set -e
      if [[ $status -ne 0 ]]; then
        echo "ERROR: TOPS coregistration failed with non-zero exit status: $status" >&2
        echo "Check: ${COREG_LOG_DIR}/S1_coreg_TOPS.inputs.log and ${COREG_LOG_DIR}/S1_coreg_TOPS.log" >&2
        print_coreg_tail
        exit 1
      fi
      ;;
    *) echo "ERROR: unknown COREG_ENGINE=$COREG_ENGINE" >&2; exit 1 ;;
  esac

  repair_zero_rslc_metadata
  if ! rslc_tab_all_outputs_exist "$SEC_RSLC_TAB_LOCAL"; then
    echo "ERROR: S1_coreg_TOPS returned status 0, but expected RSLC outputs are missing or zero-size." >&2
    echo "This usually indicates internal S1_coreg_TOPS failure, stale coreg cache, invalid imported SLC_par/TOPS_par, or no common bursts." >&2
    echo "Check: ${COREG_LOG_DIR}/S1_coreg_TOPS.inputs.log" >&2
    echo "Check: ${COREG_LOG_DIR}/S1_coreg_TOPS.log" >&2
    echo "Suggested first retry: set FORCE_COREG=1, or remove ${COREG_DIR}, then rerun." >&2
    print_coreg_tail
    exit 1
  fi
  touch "${SEC_RSLC_TAB_LOCAL}.coreg_done"
}

mosaic_tops_tab(){
  local in_tab="$1" out_slc="$2" out_par="$3" label="$4"
  local log_file="${COREG_LOG_DIR}/SLC_mosaic.${label}.log"
  local tab_base out_slc_base out_par_base
  tab_base=$(basename "$in_tab")
  out_slc_base=$(basename "$out_slc")
  out_par_base=$(basename "$out_par")

  if [[ "$FORCE_MOSAIC" -eq 0 && -s "$out_slc" && -s "$out_par" ]]; then
    log "Reuse mosaic: $(basename "$out_slc")"
    return 0
  fi

  rm -f "$out_slc" "$out_par"
  log "Mosaic TOPS swaths: $label"

  # Important for old GAMMA wrappers: SEC_RSLC_tab entries are RELATIVE paths
  # such as 20260630_iw1_vv.rslc. They must be resolved relative to COREG_DIR.
  # Therefore run SLC_mosaic_S1_TOPS inside COREG_DIR and pass local basenames.
  set +e
  (
    cd "$COREG_DIR"
    SLC_mosaic_S1_TOPS "$tab_base" "$out_slc_base" "$out_par_base" 1 1 1
  ) > "$log_file" 2>&1
  local status=$?

  # Some installations have SLC_mosaic_TOPS, but yours may not. Retry only if it exists.
  if [[ $status -ne 0 ]] && command -v SLC_mosaic_TOPS >/dev/null 2>&1; then
    echo "[auto retry] trying SLC_mosaic_TOPS" >> "$log_file"
    (
      cd "$COREG_DIR"
      SLC_mosaic_TOPS "$tab_base" "$out_slc_base" "$out_par_base" 1 1 1
    ) >> "$log_file" 2>&1
    status=$?
  fi
  set -e

  if [[ $status -ne 0 || ! -s "$out_slc" || ! -s "$out_par" ]]; then
    echo "ERROR: TOPS mosaicking failed for $label. See: $log_file" >&2
    echo "Current directory used for mosaicking: $COREG_DIR" >&2
    echo "Tab used: $in_tab" >&2
    echo "Output expected: $out_slc and $out_par" >&2
    exit 1
  fi
}

par_dim_string(){
  local par="$1"
  awk '$1=="range_samples:" {rs=$2} $1=="azimuth_lines:" {az=$2} END{if(rs!="" && az!="") print rs"x"az; else print "NA"}' "$par"
}

adopt_native_coreg_mosaics(){
  # S1_coreg_TOPS itself creates native full-resolution mosaics:
  #   ${COREG_REF}.rslc(.par) and ${COREG_SEC}.rslc(.par)
  # For S1A-S1C burst-selected cases these native products preserve the
  # exact common geometry used internally by S1_coreg_TOPS.  Re-mosaicking
  # REF_TAB and SEC_RSLC_TAB outside S1_coreg_TOPS can create different
  # map extents and then SLC_intf fails with unequal range_samples.
  local nref_slc="${COREG_DIR}/${COREG_REF}.rslc"
  local nref_par="${COREG_DIR}/${COREG_REF}.rslc.par"
  local nsec_slc="${COREG_DIR}/${COREG_SEC}.rslc"
  local nsec_par="${COREG_DIR}/${COREG_SEC}.rslc.par"

  if [[ -s "$nref_slc" && -s "$nref_par" && -s "$nsec_slc" && -s "$nsec_par" ]]; then
    local dref dsec
    dref=$(par_dim_string "$nref_par")
    dsec=$(par_dim_string "$nsec_par")
    if [[ "$dref" == "$dsec" && "$dref" != "NA" ]]; then
      log "Use native S1_coreg_TOPS mosaics: ${COREG_REF}.rslc/${COREG_SEC}.rslc (${dref})"
      rm -f "$REF_MOSAIC" "$REF_MOSAIC_PAR" "$SEC_MOSAIC" "$SEC_MOSAIC_PAR"
      ( cd "$COREG_DIR" && ln -sf "$(basename "$nref_slc")" "$(basename "$REF_MOSAIC")" )
      ( cd "$COREG_DIR" && ln -sf "$(basename "$nref_par")" "$(basename "$REF_MOSAIC_PAR")" )
      ( cd "$COREG_DIR" && ln -sf "$(basename "$nsec_slc")" "$(basename "$SEC_MOSAIC")" )
      ( cd "$COREG_DIR" && ln -sf "$(basename "$nsec_par")" "$(basename "$SEC_MOSAIC_PAR")" )
      return 0
    else
      log "Native S1_coreg_TOPS mosaics exist but dimensions differ: ref=${dref}, sec=${dsec}; try explicit mosaicking fallback"
      return 1
    fi
  fi
  return 1
}

prepare_slc_intf_common_geometry(){
  # SLC_mosaic_S1_TOPS can round the final azimuth extent by one or a few lines
  # independently for the reference and resampled secondary.  SLC_intf requires
  # equal range width, but it can explicitly process a common azimuth line count.
  # Do not fall back to the narrower native S1_coreg_TOPS mosaic just because of
  # a harmless one-line azimuth difference.
  local ref_r ref_az sec_r sec_az az_diff common_az max_diff
  ref_r=$(awk '$1=="range_samples:" {print int($2); exit}' "$REF_MOSAIC_PAR")
  ref_az=$(awk '$1=="azimuth_lines:" {print int($2); exit}' "$REF_MOSAIC_PAR")
  sec_r=$(awk '$1=="range_samples:" {print int($2); exit}' "$SEC_MOSAIC_PAR")
  sec_az=$(awk '$1=="azimuth_lines:" {print int($2); exit}' "$SEC_MOSAIC_PAR")

  if [[ -z "${ref_r:-}" || -z "${ref_az:-}" || -z "${sec_r:-}" || -z "${sec_az:-}" ]]; then
    echo "[ERROR] Cannot read range_samples/azimuth_lines from explicit mosaic parameter files." >&2
    echo "        ref=${REF_MOSAIC_PAR}" >&2
    echo "        sec=${SEC_MOSAIC_PAR}" >&2
    exit 1
  fi

  if (( ref_r != sec_r )); then
    echo "[ERROR] Coregistered SLC mosaics have different range widths; cannot run SLC_intf." >&2
    echo "        ref=${REF_MOSAIC_PAR}: ${ref_r}x${ref_az}" >&2
    echo "        sec=${SEC_MOSAIC_PAR}: ${sec_r}x${sec_az}" >&2
    echo "        Range mismatch is not a harmless mosaic rounding effect." >&2
    exit 1
  fi

  az_diff=$(( ref_az - sec_az ))
  (( az_diff < 0 )) && az_diff=$(( -az_diff ))
  common_az=$(( ref_az < sec_az ? ref_az : sec_az ))
  max_diff=${SLC_INTF_MAX_AZ_LINE_MISMATCH}

  if (( az_diff > max_diff )); then
    echo "[ERROR] Explicit mosaics differ by ${az_diff} azimuth lines, exceeding SLC_INTF_MAX_AZ_LINE_MISMATCH=${max_diff}." >&2
    echo "        ref=${ref_r}x${ref_az}; sec=${sec_r}x${sec_az}" >&2
    echo "        This may indicate different burst coverage or a coregistration/mosaic problem." >&2
    exit 1
  fi

  SLC_INTF_LOFF=0
  SLC_INTF_NLINES=${common_az}
  export SLC_INTF_LOFF SLC_INTF_NLINES

  if (( az_diff == 0 )); then
    log "SLC_intf common geometry: ${ref_r}x${common_az} (no azimuth trimming)"
  else
    log "SLC_intf common geometry: range=${ref_r}, azimuth=${common_az}; explicit mosaics differ by ${az_diff} line(s), so only the unmatched tail is omitted"
  fi
}

prepare_coreg_cache(){
  coregister_tops

  local mosaic_mode="$MOSAIC_SOURCE_MODE_RESOLVED"

  case "$mosaic_mode" in
    native)
      if ! adopt_native_coreg_mosaics; then
        log "Native common-geometry mosaics unavailable; fall back to explicit all-swath mosaicking"
        mosaic_tops_tab "$REF_TAB_LOCAL" "$REF_MOSAIC" "$REF_MOSAIC_PAR" ref
        mosaic_tops_tab "$SEC_RSLC_TAB_LOCAL" "$SEC_MOSAIC" "$SEC_MOSAIC_PAR" sec_rslc
        mosaic_mode="explicit_fallback"
      fi
      ;;
    explicit)
      mosaic_tops_tab "$REF_TAB_LOCAL" "$REF_MOSAIC" "$REF_MOSAIC_PAR" ref
      mosaic_tops_tab "$SEC_RSLC_TAB_LOCAL" "$SEC_MOSAIC" "$SEC_MOSAIC_PAR" sec_rslc
      ;;
    *)
      echo "[ERROR] Invalid MOSAIC_SOURCE_MODE=${MOSAIC_SOURCE_MODE}; use auto/native/explicit" >&2
      exit 1
      ;;
  esac
  MOSAIC_SOURCE_MODE_USED="$mosaic_mode"
  export MOSAIC_SOURCE_MODE_USED
  log "Mosaic source mode: ${MOSAIC_SOURCE_MODE_USED}; ref=$(par_dim_string "$REF_MOSAIC_PAR" 2>/dev/null || echo NA), sec=$(par_dim_string "$SEC_MOSAIC_PAR" 2>/dev/null || echo NA)"

  if [[ ! -f "$BASE" ]]; then
    base_orbit "$REF_MOSAIC_PAR" "$SEC_MOSAIC_PAR" "$BASE" > "${COREG_LOG_DIR}/base_orbit.log" 2>&1 || true
  fi
  need_nonempty "$REF_MOSAIC"
  need_nonempty "$REF_MOSAIC_PAR"
  need_nonempty "$SEC_MOSAIC"
  need_nonempty "$SEC_MOSAIC_PAR"
  prepare_slc_intf_common_geometry
}

make_interferogram(){
  if [[ "$FORCE_LOOK" -eq 1 ]]; then
    rm -f "$REF_MLI" "$REF_MLI_PAR" "$SEC_RMLI" "$SEC_RMLI_PAR" "$INT" "$CC" "$HGT" "$PH_SIM" "$DIFF_PAR" "$DIFF0" "$DIFF0_PHASE" "$OFF_LOOK" "$DIFF0".science_sign_*
    rm -rf "$LOOK_GEO_DIR"
    mkdir -p "$LOOK_GEO_DIR"
  fi

  if [[ ! -s "$REF_MLI" || ! -s "$REF_MLI_PAR" ]]; then
    log "multi_look reference ${LOOK}"
    multi_look "$REF_MOSAIC" "$REF_MOSAIC_PAR" "$REF_MLI" "$REF_MLI_PAR" "$RLKS" "$ALKS" > "${LOOK_LOG_DIR}/multi_look.ref.log" 2>&1
  else
    log "Reuse reference MLI ${LOOK}"
  fi
  if [[ ! -s "$SEC_RMLI" || ! -s "$SEC_RMLI_PAR" ]]; then
    log "multi_look secondary ${LOOK}"
    multi_look "$SEC_MOSAIC" "$SEC_MOSAIC_PAR" "$SEC_RMLI" "$SEC_RMLI_PAR" "$RLKS" "$ALKS" > "${LOOK_LOG_DIR}/multi_look.sec.log" 2>&1
  else
    log "Reuse secondary RMLI ${LOOK}"
  fi

  R_WIDTH=$(awk '$1=="range_samples:" {print $2}' "$REF_MLI_PAR")
  R_LINES=$(awk '$1=="azimuth_lines:" {print $2}' "$REF_MLI_PAR")
  export R_WIDTH R_LINES

  if [[ ! -s "$OFF_COREG" ]]; then
    printf '\n\n\n\n\n\n\n\n\n\n' | create_offset "$REF_MOSAIC_PAR" "$SEC_MOSAIC_PAR" "$OFF_COREG" 1 > "${COREG_LOG_DIR}/create_offset.fallback.log" 2>&1
    init_offset_orbit "$REF_MOSAIC_PAR" "$SEC_MOSAIC_PAR" "$OFF_COREG" > "${COREG_LOG_DIR}/init_offset_orbit.fallback.log" 2>&1 || true
  fi
  cp "$OFF_COREG" "$OFF_LOOK"

  if [[ ! -s "$INT" ]]; then
    rm -f "$INT"
    log "SLC_intf ${LOOK}"
    SLC_intf "$REF_MOSAIC" "$SEC_MOSAIC" "$REF_MOSAIC_PAR" "$SEC_MOSAIC_PAR" \
      "$OFF_LOOK" "$INT" "$RLKS" "$ALKS" \
      "$SLC_INTF_LOFF" "$SLC_INTF_NLINES" "$SPS_FLG_USED" "$AZF_FLG_USED" "$RP1_FLG" "$RP2_FLG" \
      - - - - "$AZ_BETA" > "${LOOK_LOG_DIR}/SLC_intf.log" 2>&1
  else
    log "Reuse interferogram ${LOOK}"
  fi
  if [[ ! -s "$INT" ]]; then
    echo "ERROR: SLC_intf produced an empty interferogram: $INT" >&2
    echo "Check ${LOOK_LOG_DIR}/SLC_intf.log" >&2
    exit 1
  fi

  if [[ ! -s "$CC" ]]; then
    log "cc_wave ${LOOK}"
    cc_wave "$INT" "$REF_MLI" "$SEC_RMLI" "$CC" "$R_WIDTH" 5 5 1 > "${LOOK_LOG_DIR}/cc_wave.log" 2>&1
  else
    log "Reuse coherence ${LOOK}"
  fi

  INT_LINES=$(python3 - <<PY
import os
w = int('${R_WIDTH}')
print(os.path.getsize('${INT}') // (8*w))
PY
)
  export INT_LINES
}

run_quality_check(){
  QC_REPORT="${LOOK_DIR}/AUTO_QC.txt"
  QC_ENV="${LOOK_DIR}/AUTO_QC.env"
  QC_PASS=1
  QC_SCORE=1.0
  QC_WORST_SWATH="none"

  if [[ "$QC_ENABLE" -ne 1 ]]; then
    printf 'QC_PASS=1\nQC_SCORE=1.0\nQC_WORST_SWATH=disabled\n' > "$QC_ENV"
    return 0
  fi

  export QC_REPORT QC_ENV REF_TAB_LOCAL REF_MOSAIC_PAR CC R_WIDTH R_LINES RLKS
  export REF_MLI SEC_RMLI INT QC_MIN_SWATH_NONZERO QC_MIN_SWATH_MEAN QC_MIN_SWATH_P75 QC_ZERO_EPS
  python3 - <<'PY_QC'
import os, math, shlex
import numpy as np

report=os.environ['QC_REPORT']; envfile=os.environ['QC_ENV']
ref_tab=os.environ['REF_TAB_LOCAL']; mosaic_par=os.environ['REF_MOSAIC_PAR']
cc_file=os.environ['CC']; width=int(float(os.environ['R_WIDTH'])); lines=int(float(os.environ['R_LINES']))
rlks=int(float(os.environ['RLKS']))
min_nz=float(os.environ['QC_MIN_SWATH_NONZERO']); min_mean=float(os.environ['QC_MIN_SWATH_MEAN'])
min_p75=float(os.environ['QC_MIN_SWATH_P75']); eps=float(os.environ['QC_ZERO_EPS'])

def parvals(path):
    d={}
    with open(path, errors='ignore') as f:
        for line in f:
            p=line.replace(':',' ').split()
            if len(p)>=2:
                try: d[p[0]]=float(p[1])
                except Exception: pass
    return d

def q(path): return shlex.quote(str(path))

def product_stats(path, dtype):
    if not path or not os.path.exists(path): return (0.0,0.0)
    a=np.fromfile(path,dtype=dtype)
    if np.iscomplexobj(a): a=np.abs(a)
    a=a[np.isfinite(a)]
    if a.size==0: return (0.0,0.0)
    return (float(np.mean(a>eps)), float(np.mean(a)))

cc=np.fromfile(cc_file,dtype='>f4')
need=width*lines
if cc.size < need:
    raise RuntimeError(f'coherence file too small: {cc.size} < {need}')
cc=cc[:need].reshape(lines,width)
mp=parvals(mosaic_par)
near_m=mp.get('near_range_slc', mp.get('near_range', None))
dr=mp.get('range_pixel_spacing', None)
rows=[]
with open(ref_tab) as f:
    raw=[ln for ln in f if len(ln.split())>=2 and not ln.lstrip().startswith('#')]
for idx,line in enumerate(raw):
    p=line.split(); slc,par=p[0],p[1]
    base=os.path.basename(slc).lower()
    iw=next((x for x in ('iw1','iw2','iw3') if x in base), f'iw{idx+1}')
    pp=parvals(par); n=int(pp.get('range_samples',0))
    near_i=pp.get('near_range_slc', pp.get('near_range', None))
    if near_m is not None and near_i is not None and dr not in (None,0) and n>0:
        c0=int(math.floor(((near_i-near_m)/dr)/rlks))
        c1=int(math.ceil((((near_i-near_m)/dr)+n)/rlks))
    else:
        nsw=max(1,len(raw)); c0=int(round(idx*width/nsw)); c1=int(round((idx+1)*width/nsw))
    c0=max(0,min(width-1,c0)); c1=max(c0+1,min(width,c1))
    trim=max(0,int((c1-c0)*0.05)); a0=c0+trim; a1=max(a0+1,c1-trim)
    v=cc[:,a0:a1]
    v=v[np.isfinite(v) & (v>=0) & (v<=1)]
    if v.size:
        nz=float(np.mean(v>eps)); mean=float(np.mean(v)); med=float(np.median(v)); p75=float(np.percentile(v,75))
    else:
        nz=mean=med=p75=0.0
    passed=(nz>=min_nz) and ((mean>=min_mean) or (p75>=min_p75))
    score=min(nz/max(min_nz,1e-12), max(mean/max(min_mean,1e-12), p75/max(min_p75,1e-12)))
    rows.append((iw,c0,c1,nz,mean,med,p75,passed,score))

qc_pass=bool(rows) and all(r[7] for r in rows)
score=min((r[8] for r in rows), default=0.0)
worst=min(rows,key=lambda r:r[8])[0] if rows else 'none'
ref_nz,ref_mean=product_stats(os.environ.get('REF_MLI',''),'>f4')
sec_nz,sec_mean=product_stats(os.environ.get('SEC_RMLI',''),'>f4')
int_nz,int_mean=product_stats(os.environ.get('INT',''),'>c8')
with open(report,'w') as f:
    f.write(f'QC_PASS={int(qc_pass)}\nQC_SCORE={score:.6f}\nQC_WORST_SWATH={worst}\n')
    f.write(f'thresholds: nonzero={min_nz} mean={min_mean} p75={min_p75}\n')
    f.write(f'products: ref_mli_nonzero={ref_nz:.6f} sec_rmli_nonzero={sec_nz:.6f} int_nonzero={int_nz:.6f}\n')
    for r in rows:
        f.write(f'{r[0]} cols={r[1]}:{r[2]} nonzero={r[3]:.6f} mean={r[4]:.6f} median={r[5]:.6f} p75={r[6]:.6f} pass={int(r[7])}\n')
with open(envfile,'w') as f:
    f.write(f'QC_PASS={int(qc_pass)}\nQC_SCORE={score:.6f}\nQC_WORST_SWATH={q(worst)}\nQC_REPORT={q(report)}\n')
print(f'[QC] pass={int(qc_pass)} score={score:.3f} worst={worst}')
for r in rows:
    print(f'[QC] {r[0]} nonzero={r[3]:.3f} mean={r[4]:.3f} p75={r[6]:.3f} pass={int(r[7])}')
PY_QC

  # shellcheck disable=SC1090
  source "$QC_ENV"
  if [[ "$QC_PASS" -ne 1 ]]; then
    if [[ "$QC_ENFORCE" -eq 1 ]]; then
      echo "[QC] Candidate rejected; see $QC_REPORT" >&2
      return 42
    fi
    echo "[QC] WARNING: catastrophic/near-zero coherence detected in ${QC_WORST_SWATH}; see $QC_REPORT" >&2
  fi
  return 0
}

DEM_ID_FILE="${LOOK_DIR}/DEM_INPUT_ID.txt"
CURRENT_DEM_ID=""

dem_identity(){
  local dem_real par_real size mtime par_sha
  dem_real=$(readlink -f "$DEM")
  par_real=$(readlink -f "$DEM_PAR")
  size=$(stat -c '%s' "$DEM")
  mtime=$(stat -c '%Y' "$DEM")
  par_sha=$(sha256sum "$DEM_PAR" | awk '{print $1}')
  printf 'DEM=%s\nDEM_PAR=%s\nDEM_SIZE=%s\nDEM_MTIME=%s\nDEM_PAR_SHA256=%s\n' "$dem_real" "$par_real" "$size" "$mtime" "$par_sha"
}

detect_dem_change(){
  CURRENT_DEM_ID=$(dem_identity)
  if [[ -s "$DEM_ID_FILE" ]] && [[ "$(cat "$DEM_ID_FILE")" != "$CURRENT_DEM_ID" ]]; then
    log "DEM input changed since the cached geocoding products were built; invalidate look/geocode and downstream caches"
    FORCE_LOOK=1; FORCE_ADF=1; FORCE_SNAPHU=1; FORCE_PLOT=1; FORCE_GRD=1
  fi
}

record_dem_identity(){
  printf '%s' "$CURRENT_DEM_ID" > "$DEM_ID_FILE"
}

prepare_geocode_and_height(){
  mkdir -p "$LOOK_GEO_DIR"
  cd "$LOOK_GEO_DIR"

  python3 - "$DEM_PAR" <<'PY_DEM_EXTENT'
import re,sys
p=sys.argv[1]; d={}
with open(p,errors='ignore') as f:
    for line in f:
        m=re.match(r'^\s*(\S+):\s+([+-]?[0-9.eE+-]+)',line)
        if m:
            try:d[m.group(1)]=float(m.group(2))
            except:pass
need=['corner_lon','corner_lat','post_lon','post_lat','width','nlines']
if all(k in d for k in need):
    x0=d['corner_lon']; y0=d['corner_lat']; x1=x0+(int(d['width'])-1)*d['post_lon']; y1=y0+(int(d['nlines'])-1)*d['post_lat']
    print(f"[GEOCODE] source DEM extent: lon={min(x0,x1):.8f}..{max(x0,x1):.8f}, lat={min(y0,y1):.8f}..{max(y0,y1):.8f}, shape={int(d['nlines'])}x{int(d['width'])}")
else:
    print(f"[GEOCODE] warning: cannot derive DEM extent from {p}",file=sys.stderr)
PY_DEM_EXTENT
  ln -sf "$REF_MLI" .
  ln -sf "$REF_MLI_PAR" .
  ln -sf "$DEM" EQA.dem
  ln -sf "$DEM_PAR" EQA.dem_par

  if [[ "$FORCE_LOOK" -eq 1 ]]; then
    rm -f "${PAIR}_${LOOK}.lt" "${PAIR}_${LOOK}.lt_fine" EQA.rdc.dem_par EQA.rdc.dem "$HGT"
  fi

  if [[ ! -f "${PAIR}_${LOOK}.lt_fine" || ! -f EQA.rdc.dem_par ]]; then
    log "gc_map + lookup refinement ${LOOK}"
    gc_map "$(basename "$REF_MLI_PAR")" - EQA.dem_par EQA.dem \
      EQA.rdc.dem_par EQA.rdc.dem "${PAIR}_${LOOK}.lt" \
      "$LAT_OVR" "$LON_OVR" "${PAIR}_${LOOK}.sim_sar" u v inc psi pix ls_map 8 1 \
      > "${LOOK_LOG_DIR}/gc_map.log" 2>&1

    MAP_WIDTH=$(awk '$1=="width:" {print $2}' EQA.rdc.dem_par)
    MAP_LINES=$(awk '$1=="nlines:" {print $2}' EQA.rdc.dem_par)
    export MAP_WIDTH MAP_LINES

    pixel_area "$(basename "$REF_MLI_PAR")" EQA.rdc.dem_par EQA.rdc.dem "${PAIR}_${LOOK}.lt" \
      ls_map inc pix_sigma0 pix_Gamma0 > "${LOOK_LOG_DIR}/pixel_area.log" 2>&1

    printf '\n\n\n\n\n\n\n\n\n\n' | create_diff_par "$(basename "$REF_MLI_PAR")" - "${PAIR}_${LOOK}.geo.diff_par" 1 0 \
      > "${LOOK_LOG_DIR}/create_diff_par.geo.log" 2>&1

    offset_pwrm pix_sigma0 "$(basename "$REF_MLI")" "${PAIR}_${LOOK}.geo.diff_par" \
      "${PAIR}_${LOOK}.geo.offs" "${PAIR}_${LOOK}.geo.snr" \
      "$GEO_OFF_WIN_R" "$GEO_OFF_WIN_A" offsets "$GEO_OFF_OVR" "$GEO_OFF_NR" "$GEO_OFF_NAZ" "$GEO_OFF_CC_THR" \
      > "${LOOK_LOG_DIR}/offset_pwrm.geo.log" 2>&1 || true

    offset_fitm "${PAIR}_${LOOK}.geo.offs" "${PAIR}_${LOOK}.geo.snr" \
      "${PAIR}_${LOOK}.geo.diff_par" coffs coffsets "$GEO_FIT_CC_THR" "$GEO_FIT_NPAR" \
      > "${LOOK_LOG_DIR}/offset_fitm.geo.log" 2>&1 || true

    gc_map_fine "${PAIR}_${LOOK}.lt" "$MAP_WIDTH" "${PAIR}_${LOOK}.geo.diff_par" "${PAIR}_${LOOK}.lt_fine" 1 \
      > "${LOOK_LOG_DIR}/gc_map_fine.log" 2>&1
  else
    MAP_WIDTH=$(awk '$1=="width:" {print $2}' EQA.rdc.dem_par)
    MAP_LINES=$(awk '$1=="nlines:" {print $2}' EQA.rdc.dem_par)
    export MAP_WIDTH MAP_LINES
    log "Reuse geocode lookup ${LOOK}"
  fi

  if [[ ! -s "$HGT" ]]; then
    log "Geocode DEM to radar coordinates ${LOOK}"
    geocode "${PAIR}_${LOOK}.lt_fine" EQA.rdc.dem "$MAP_WIDTH" \
      "$HGT" "$R_WIDTH" "$INT_LINES" 1 0 > "${LOOK_LOG_DIR}/geocode_dem_to_radar.log" 2>&1
  else
    log "Reuse radar-coordinate DEM ${LOOK}"
  fi

  cd "$LOOK_DIR"
  record_dem_identity
}

apply_science_phase_sign_to_complex(){
  local fn="$1" marker="$1.science_sign_${OUTPUT_PHASE_SIGN}"
  if [[ -f "$marker" ]]; then
    return 0
  fi
  rm -f "$1.science_sign_"* 2>/dev/null || true
  if [[ "$OUTPUT_PHASE_SIGN" == "-1" ]]; then
    log "Apply science-direction phase sign: conjugate $(basename "$fn")"
    python3 - <<PY_SIGN
import numpy as np
fn='${fn}'
arr=np.fromfile(fn, dtype='>f4')
if arr.size % 2 != 0:
    raise RuntimeError(f'complex file has odd float count: {fn}, count={arr.size}')
arr=arr.reshape(-1,2)
arr[:,1] *= -1.0
arr.astype('>f4').tofile(fn)
PY_SIGN
  fi
  : > "$marker"
}

remove_topo(){
  if [[ ! -s "$PH_SIM" ]]; then
    log "phase_sim ${LOOK}"
    phase_sim "$REF_MOSAIC_PAR" "$OFF_LOOK" "$BASE" "$HGT" "$PH_SIM" \
      0 0 - - 1 - 0 > "${LOOK_LOG_DIR}/phase_sim.log" 2>&1
  else
    log "Reuse simulated phase ${LOOK}"
  fi

  if [[ ! -s "$DIFF_PAR" ]]; then
    printf '\n\n\n\n\n\n\n\n\n\n' | create_diff_par "$OFF_LOOK" - "$DIFF_PAR" 0 > "${LOOK_LOG_DIR}/create_diff_par.diff.log" 2>&1
  fi

  if [[ ! -s "$DIFF0" ]]; then
    log "sub_phase ${LOOK}"
    sub_phase "$INT" "$PH_SIM" "$DIFF_PAR" "$DIFF0" 1 0 > "${LOOK_LOG_DIR}/sub_phase.log" 2>&1
  else
    log "Reuse differential interferogram ${LOOK}"
  fi

  apply_science_phase_sign_to_complex "$DIFF0"

  if [[ ! -s "$DIFF0_PHASE" ]]; then
    log "Extract unfiltered wrapped phase ${LOOK}"
    python3 - <<PY
import numpy as np
w = int('${R_WIDTH}')
fn = '${DIFF0}'
arr = np.fromfile(fn, dtype='>f4')
if arr.size % (2*w) != 0:
    raise RuntimeError(f'Unexpected complex file size: {arr.size}, width={w}, file={fn}')
arr = arr.reshape(-1, w, 2)
phase = np.arctan2(arr[:, :, 1], arr[:, :, 0]).astype('>f4')
phase.tofile('${DIFF0_PHASE}')
PY
  fi
}

run_adf(){
  if [[ "$FORCE_ADF" -eq 1 ]]; then
    rm -f "$DIFF0_ADF" "$DIFF0_ADF_CC" "$DIFF0_ADF_PHASE" "$DIFF0_ADF_UNW" "$DIFF0_ADF_UNW_NATIVE" "$DIFF0_ADF_LOS_M"
    rm -rf "$ADF_GEO_DIR"
    mkdir -p "$ADF_GEO_DIR"
  fi

  if [[ ! -s "$DIFF0_ADF" || ! -s "$DIFF0_ADF_CC" ]]; then
    log "adf alpha=${ADF_ALPHA} nfft=${ADF_NFFT} ccwin=${ADF_CCWIN}"
    adf "$DIFF0" "$DIFF0_ADF" "$DIFF0_ADF_CC" \
      "$R_WIDTH" "$ADF_ALPHA" "$ADF_NFFT" "$ADF_CCWIN" > "${ADF_LOG_DIR}/adf.log" 2>&1
  else
    log "Reuse ADF output ${ADF_TAG}"
  fi

  if [[ ! -s "$DIFF0_ADF_PHASE" ]]; then
    log "Extract ADF wrapped phase ${ADF_TAG}"
    python3 - <<PY
import numpy as np
w = int('${R_WIDTH}')
fn = '${DIFF0_ADF}'
arr = np.fromfile(fn, dtype='>f4')
if arr.size % (2*w) != 0:
    raise RuntimeError(f'Unexpected complex file size: {arr.size}, width={w}, file={fn}')
arr = arr.reshape(-1, w, 2)
phase = np.arctan2(arr[:, :, 1], arr[:, :, 0]).astype('>f4')
phase.tofile('${DIFF0_ADF_PHASE}')
PY
  fi
}

unwrap_direct_engine(){
  if [[ "$DO_UNWRAP" -ne 1 || "$UNW_ENGINE" == "none" ]]; then
    log "DO_UNWRAP=0 or UNW_ENGINE=none; skip unwrapping"
    return 0
  fi

  if [[ "$FORCE_SNAPHU" -eq 0 && -s "$DIFF0_ADF_UNW" && -s "$DIFF0_ADF_LOS_M" ]]; then
    log "Reuse ${UNW_ENGINE} unwrap and LOS"
    return 0
  fi

  rm -f "$DIFF0_ADF_UNW" "$DIFF0_ADF_UNW_NATIVE" "$DIFF0_ADF_UNW_RAW" "$DIFF0_ADF_LOS_M" "$DIFF0_ADF_LOS_M_RAW" "$DIFF0_ADF_UNW_MASK" "$SNAPHU_QC" 2>/dev/null || true

  case "$UNW_ENGINE" in
    snaphu)
      if ! command -v snaphu >/dev/null 2>&1; then
        echo "WARNING: snaphu command not found; skip SNAPHU unwrapping." >&2
        return 0
      fi
      log "SNAPHU unwrap INIT=${SNAPHU_INIT_METHOD} COST=${SNAPHU_COST_MODE} coh>=${UNW_COH_THRESHOLD}"
      python3 - <<PY_SNAPHU_PREP
import numpy as np, os
w = int('${R_WIDTH}')
phase = np.fromfile('${DIFF0_ADF_PHASE}', dtype='>f4')
cc = np.fromfile('${DIFF0_ADF_CC}', dtype='>f4')
if phase.size != cc.size:
    raise RuntimeError(f'phase/coherence size mismatch: {phase.size} vs {cc.size}')
phase.astype(np.float32).tofile('${SNAPHU_PHASE_NATIVE}')
floor = float('${SNAPHU_CORR_FLOOR}')
cc2 = np.where(np.isfinite(cc), np.clip(cc, floor, 1.0), floor)
cc2 = np.where(cc >= float('${UNW_COH_THRESHOLD}'), cc2, floor).astype(np.float32)
cc2.tofile('${SNAPHU_CC_NATIVE}')
PY_SNAPHU_PREP
      cat > "$SNAPHU_CONF" <<CONF_SNAPHU
STATCOSTMODE ${SNAPHU_COST_MODE}
INITMETHOD ${SNAPHU_INIT_METHOD}
INFILEFORMAT FLOAT_DATA
OUTFILEFORMAT FLOAT_DATA
CORRFILE ${SNAPHU_CC_NATIVE}
CORRFILEFORMAT FLOAT_DATA
NCORRLOOKS ${SNAPHU_NCORRLOOKS}
NLOOKSRANGE ${RLKS}
NLOOKSAZ ${ALKS}
CONF_SNAPHU
      set +e
      snaphu -f "$SNAPHU_CONF" $SNAPHU_EXTRA_OPTS -o "$DIFF0_ADF_UNW_NATIVE" "$SNAPHU_PHASE_NATIVE" "$R_WIDTH" > "${ADF_LOG_DIR}/snaphu.log" 2>&1
      local status=$?
      set -e
      if [[ $status -ne 0 || ! -s "$DIFF0_ADF_UNW_NATIVE" ]]; then
        echo "WARNING: SNAPHU unwrapping failed; wrapped outputs are still valid." >&2
        echo "Check: ${ADF_LOG_DIR}/snaphu.log and ${SNAPHU_CONF}" >&2
        return 0
      fi
      ;;

    gamma_mcf)
      log "Attempt GAMMA MCF unwrapping, no fault split/barrier"
      local unw_mask="${ADF_DIR}/${PAIR}_${LOOK}.gamma_mcf.unw_mask.bmp"
      set +e
      rascc_mask "$DIFF0_ADF_CC" "$REF_MLI" "$R_WIDTH" 1 1 0 1 1 "$UNW_COH_THRESHOLD" 0.0 0.0 1.0 1.0 0.35 1 "$unw_mask" \
        > "${ADF_LOG_DIR}/rascc_mask.gamma_mcf.log" 2>&1
      local status_mask=$?
      mcf "$DIFF0_ADF" "$DIFF0_ADF_CC" "$unw_mask" "$DIFF0_ADF_UNW_RAW" "$R_WIDTH" 1 0 0 - - 1 1 - - - 1 \
        > "${ADF_LOG_DIR}/mcf_unwrap.log" 2>&1
      local status_mcf=$?
      set -e
      if [[ $status_mask -ne 0 || $status_mcf -ne 0 || ! -s "$DIFF0_ADF_UNW_RAW" ]]; then
        echo "WARNING: GAMMA mcf unwrapping failed; wrapped outputs are still valid." >&2
        echo "Check: ${ADF_LOG_DIR}/mcf_unwrap.log and ${ADF_LOG_DIR}/rascc_mask.gamma_mcf.log" >&2
        return 0
      fi
      python3 - <<PY_MCF_CONVERT
import numpy as np
phase=np.fromfile('${DIFF0_ADF_PHASE}', dtype='>f4')
raw=np.fromfile('${DIFF0_ADF_UNW_RAW}', dtype='>f4')
if raw.size != phase.size:
    raise RuntimeError(f'GAMMA MCF unw size mismatch: {raw.size} vs phase {phase.size}')
raw.astype(np.float32).tofile('${DIFF0_ADF_UNW_NATIVE}')
PY_MCF_CONVERT
      ;;

    mk_unw_2d)
      if ! command -v mk_unw_2d >/dev/null 2>&1; then
        echo "WARNING: mk_unw_2d command not found; skip mk_unw_2d unwrapping." >&2
        return 0
      fi
      log "Attempt GAMMA mk_unw_2d, mode=${MKUNW_MODE}, cc=${MKUNW_CC_THRES}, nlks=${MKUNW_NLKS}, patches=${MKUNW_NPAT_R}x${MKUNW_NPAT_AZ}"
      rm -rf "$MKUNW_DIR"
      mkdir -p "$MKUNW_DIFF_DIR"

      # mk_unw_2d derives the expected interferogram base name from the SLC IDs in RSLC_tab.
      # Passing original mosaic names (20260618_vv.slc and 20260630_vv.rslc) makes mk_unw_2d
      # look for diff/20260618_vv_20260630_vv.off.  Stage simple local names instead, so
      # the expected pair base is ${REF}_${SEC}, matching our existing pair convention.
      local mk_ref_slc="${MKUNW_DIR}/${COREG_REF}.rslc"
      local mk_ref_par="${MKUNW_DIR}/${COREG_REF}.rslc.par"
      local mk_sec_slc="${MKUNW_DIR}/${COREG_SEC}.rslc"
      local mk_sec_par="${MKUNW_DIR}/${COREG_SEC}.rslc.par"
      local mk_pair="${COREG_REF}_${COREG_SEC}"

      ln -sf "$REF_MOSAIC"     "$mk_ref_slc"
      ln -sf "$REF_MOSAIC_PAR" "$mk_ref_par"
      ln -sf "$SEC_MOSAIC"     "$mk_sec_slc"
      ln -sf "$SEC_MOSAIC_PAR" "$mk_sec_par"

      # mk_unw_2d requires the pair .off parameter file inside diff_dir, plus pair-named
      # diff/adf.diff/adf.cc products.  Missing ${mk_pair}.off caused the v9.2.3 failure.
      ln -sf "$OFF_LOOK"       "$MKUNW_DIFF_DIR/${mk_pair}.off"
      ln -sf "$DIFF0"          "$MKUNW_DIFF_DIR/${mk_pair}.diff"
      ln -sf "$DIFF0_ADF"      "$MKUNW_DIFF_DIR/${mk_pair}.adf.diff"
      ln -sf "$DIFF0_ADF_CC"   "$MKUNW_DIFF_DIR/${mk_pair}.adf.cc"
      ln -sf "$DIFF0_ADF_CC"   "$MKUNW_DIFF_DIR/${mk_pair}.cc"

      printf "%s %s
%s %s
" "$mk_ref_slc" "$mk_ref_par" "$mk_sec_slc" "$mk_sec_par" > "$MKUNW_RSLC_TAB"
      printf "1 2 1 1
" > "$MKUNW_ITAB"
      {
        echo "MKUNW_DIR=$MKUNW_DIR"
        echo "MKUNW_DIFF_DIR=$MKUNW_DIFF_DIR"
        echo "MKUNW_PAIR_BASE=$mk_pair"
        echo "Expected files staged in diff_dir:"
        ls -lh "$MKUNW_DIFF_DIR/${mk_pair}.off" "$MKUNW_DIFF_DIR/${mk_pair}.diff" "$MKUNW_DIFF_DIR/${mk_pair}.adf.diff" "$MKUNW_DIFF_DIR/${mk_pair}.adf.cc" 2>/dev/null || true
        echo "RSLC_tab=$MKUNW_RSLC_TAB"
        cat "$MKUNW_RSLC_TAB"
        echo "itab=$MKUNW_ITAB"
        cat "$MKUNW_ITAB"
        echo "Command: mk_unw_2d $MKUNW_RSLC_TAB $MKUNW_ITAB $REF_MLI $MKUNW_DIFF_DIR $MKUNW_CC_THRES $MKUNW_PWR_THRES $MKUNW_NLKS $MKUNW_NPAT_R $MKUNW_NPAT_AZ $MKUNW_MODE $MKUNW_R_INIT $MKUNW_AZ_INIT $MKUNW_TRI_MODE $MKUNW_MASK $MKUNW_ROFF $MKUNW_LOFF $MKUNW_NR $MKUNW_NLINES"
      } > "${ADF_LOG_DIR}/mk_unw_2d.inputs.log"

      set +e
      mk_unw_2d "$MKUNW_RSLC_TAB" "$MKUNW_ITAB" "$REF_MLI" "$MKUNW_DIFF_DIR" \
        "$MKUNW_CC_THRES" "$MKUNW_PWR_THRES" "$MKUNW_NLKS" "$MKUNW_NPAT_R" "$MKUNW_NPAT_AZ" "$MKUNW_MODE" \
        "$MKUNW_R_INIT" "$MKUNW_AZ_INIT" "$MKUNW_TRI_MODE" "$MKUNW_MASK" "$MKUNW_ROFF" "$MKUNW_LOFF" "$MKUNW_NR" "$MKUNW_NLINES" \
        > "$MKUNW_LOG" 2>&1
      local status_mkunw=$?
      set -e
      # mk_unw_2d usually writes both the binary unwrapped phase (*.unw, float)
      # and display images (*.unw.bmp/*.ras/*.tif).  The v9.2.4 selector used *.unw*,
      # so it could accidentally pick the BMP quicklook.  Here we list all possible
      # files for debugging, but the Python selector below accepts only files whose
      # size matches the radar-grid float image.
      find "$MKUNW_DIFF_DIR" -maxdepth 1 -type f \( -name "*.unw" -o -name "*.unw0" -o -name "*.unw*" \) -printf "%T@ %s %p\n" | sort -n > "$MKUNW_OUT_LIST" || true
      if [[ $status_mkunw -ne 0 ]]; then
        echo "WARNING: mk_unw_2d returned non-zero status: $status_mkunw" >&2
        echo "Check: $MKUNW_LOG and ${ADF_LOG_DIR}/mk_unw_2d.inputs.log" >&2
        echo "Candidate outputs listed in: $MKUNW_OUT_LIST" >&2
        return 0
      fi
      export MKUNW_DIFF_DIR MKUNW_OUT_LIST
      python3 - <<PY_MKUNW_CONVERT
import os, glob, numpy as np
phase=np.fromfile('${DIFF0_ADF_PHASE}', dtype='>f4')
expected_bytes=phase.size*4
diff_dir=os.environ['MKUNW_DIFF_DIR']
out_list=os.environ['MKUNW_OUT_LIST']

# Prefer true GAMMA float outputs.  Exclude display rasters/quicklooks explicitly.
all_files=[]
for pat in ('*.unw','*.unw0','*.unw*'):
    all_files.extend(glob.glob(os.path.join(diff_dir, pat)))
seen=[]
for f in all_files:
    if f not in seen:
        seen.append(f)

def is_display(fn):
    lo=fn.lower()
    return lo.endswith(('.bmp','.ras','.tif','.tiff','.png','.jpg','.jpeg'))

candidates=[]
with open(out_list, 'a') as fo:
    fo.write('\n[python selector] expected_float_bytes=%d expected_pixels=%d\n' % (expected_bytes, phase.size))
    for f in sorted(seen, key=lambda x: os.path.getmtime(x)):
        try:
            sz=os.path.getsize(f)
        except OSError:
            continue
        fo.write('[python selector] file=%s bytes=%d display=%s\n' % (f, sz, is_display(f)))
        if (not is_display(f)) and sz == expected_bytes:
            candidates.append(f)

if not candidates:
    raise RuntimeError('mk_unw_2d produced no binary float *.unw file with expected size. See candidate list: %s' % out_list)

# Use the newest matching binary output.  For mode=1 this is usually <pair>.adf.unw.
src=sorted(candidates, key=lambda x: os.path.getmtime(x))[-1]
cands=[]
for dt in ['>f4','<f4']:
    arr=np.fromfile(src, dtype=dt)
    if arr.size == phase.size:
        finite=np.isfinite(arr) & np.isfinite(phase)
        if np.count_nonzero(finite) == 0:
            med=float('inf')
        else:
            d=np.angle(np.exp(1j*(arr[finite].astype(np.float64)-phase[finite].astype(np.float64))))
            med=float(np.nanmedian(np.abs(d)))
        cands.append((med,dt,arr))
if not cands:
    raise RuntimeError(f'mk_unw_2d selected output is not a float grid: file={src}, bytes={os.path.getsize(src)}, expected_bytes={expected_bytes}')
med,dt,arr=sorted(cands, key=lambda x:x[0])[0]
print(f'[MK_UNW_2D] selected binary output: {src}')
print(f'[MK_UNW_2D] selected dtype: {dt}, median wrap(unw-phase)={med}')
with open('${MKUNW_DIR}/selected_unw_output.txt','w') as f:
    f.write(src+'\n')
    f.write(f'dtype={dt}\n')
    f.write(f'median_wrap_unw_minus_phase={med}\n')
arr.astype(np.float32).tofile('${DIFF0_ADF_UNW_NATIVE}')
PY_MKUNW_CONVERT
      ;;

    *)
      echo "WARNING: unknown UNW_ENGINE=$UNW_ENGINE; skip unwrapping" >&2
      return 0
      ;;
  esac

  python3 - <<PY_POST_UNW
import numpy as np, math, os
w = int('${R_WIDTH}')
phase = np.fromfile('${DIFF0_ADF_PHASE}', dtype='>f4')
cc = np.fromfile('${DIFF0_ADF_CC}', dtype='>f4')
unw_native = np.fromfile('${DIFF0_ADF_UNW_NATIVE}', dtype=np.float32)
if unw_native.size != phase.size:
    raise RuntimeError(f'unwrapped size mismatch: {unw_native.size} vs phase {phase.size}')
shape = (-1, w)
phase2 = phase.reshape(shape)
cc2 = cc.reshape(shape)
unw = unw_native.reshape(shape).astype(np.float64)
d = np.angle(np.exp(1j*(unw - phase2)))
valid_d = np.isfinite(d)
med_abs = float(np.nanmedian(np.abs(d[valid_d]))) if valid_d.any() else float('nan')
p90, p99 = (np.nanpercentile(np.abs(d[valid_d]), [90, 99]).tolist() if valid_d.any() else [float('nan'), float('nan')])
hgt_file='${HGT}'
hgt = None
if os.path.exists(hgt_file) and os.path.getsize(hgt_file) > 0:
    h = np.fromfile(hgt_file, dtype='>f4')
    if h.size == phase.size:
        hgt = h.reshape(shape)
land_ok = np.ones_like(cc2, dtype=bool)
if int('${UNW_OUTPUT_WATER_MASK}') == 1 and hgt is not None:
    land_ok &= np.isfinite(hgt) & (hgt > float('${UNW_OUTPUT_WATER_THRESHOLD}'))
out_ok = np.isfinite(unw) & np.isfinite(cc2) & land_ok
if int('${UNW_OUTPUT_APPLY_MASK}') == 1:
    out_ok &= (cc2 >= float('${UNW_OUTPUT_COH_THRESHOLD}'))
ref_ok = np.isfinite(unw) & np.isfinite(cc2) & land_ok & (cc2 >= float('${UNW_REF_COH_THRESHOLD}'))
ref_mode='${UNW_REF_MODE}'.lower()
ref_value = 0.0
plane_coeff = None
unw_corr = unw.copy()
if ref_mode == 'none':
    ref_value = 0.0
elif ref_mode == 'global':
    if np.count_nonzero(ref_ok) < 100:
        print('[UNW_QC] WARNING: too few reference pixels; no reference correction applied')
    else:
        ref_value = float(np.nanmedian(unw[ref_ok]))
        unw_corr = unw_corr - ref_value
else:
    print(f'[UNW_QC] WARNING: unsupported UNW_REF_MODE={ref_mode!r}; using no reference correction')
if int('${UNW_REMOVE_PLANE}') == 1 and np.count_nonzero(ref_ok) >= 1000:
    yy, xx = np.indices(unw.shape)
    A = np.c_[xx[ref_ok].ravel(), yy[ref_ok].ravel(), np.ones(np.count_nonzero(ref_ok))]
    b = unw_corr[ref_ok].ravel()
    try:
        coeff, *_ = np.linalg.lstsq(A, b, rcond=None)
        plane = coeff[0]*xx + coeff[1]*yy + coeff[2]
        unw_corr = unw_corr - plane
        plane_coeff = [float(x) for x in coeff]
    except Exception as e:
        print('[UNW_QC] WARNING: plane removal failed:', e)
unw_raw = unw.astype(np.float32)
los_raw = float('${LOS_SIGN}') * unw_raw * float('${WAVELENGTH_M}') / (4.0*math.pi)
unw_out = unw_corr.astype(np.float32)
los_out = float('${LOS_SIGN}') * unw_out * float('${WAVELENGTH_M}') / (4.0*math.pi)
if int('${UNW_OUTPUT_APPLY_MASK}') == 1:
    unw_out[~out_ok] = np.nan
    los_out[~out_ok] = np.nan
valid_los = np.isfinite(los_out)
if valid_los.any():
    los_min = float(np.nanmin(los_out[valid_los]))
    los_p01, los_p50, los_p99 = [float(x) for x in np.nanpercentile(los_out[valid_los], [1, 50, 99])]
    los_max = float(np.nanmax(los_out[valid_los]))
else:
    los_min = los_p01 = los_p50 = los_p99 = los_max = float('nan')
unw_raw.astype('>f4').tofile('${DIFF0_ADF_UNW_RAW}')
los_raw.astype('>f4').tofile('${DIFF0_ADF_LOS_M_RAW}')
unw_out.astype('>f4').tofile('${DIFF0_ADF_UNW}')
los_out.astype('>f4').tofile('${DIFF0_ADF_LOS_M}')
out_ok.astype(np.uint8).tofile('${DIFF0_ADF_UNW_MASK}')
with open('${SNAPHU_QC}', 'w') as f:
    f.write(f'unwrap_engine: ${UNW_ENGINE}\n')
    f.write(f'unwrap_tag: ${UNW_TAG}\n')
    f.write(f'mkunw_cc_thres: ${MKUNW_CC_THRES}\n')
    f.write(f'mkunw_pwr_thres: ${MKUNW_PWR_THRES}\n')
    f.write(f'mkunw_nlks: ${MKUNW_NLKS}\n')
    f.write(f'mkunw_npat_r: ${MKUNW_NPAT_R}\n')
    f.write(f'mkunw_npat_az: ${MKUNW_NPAT_AZ}\n')
    f.write(f'mkunw_mode: ${MKUNW_MODE}\n')
    f.write(f'wrap_unw_minus_phase_median_abs_rad: {med_abs}\n')
    f.write(f'wrap_unw_minus_phase_p90_abs_rad: {p90}\n')
    f.write(f'wrap_unw_minus_phase_p99_abs_rad: {p99}\n')
    f.write(f'unw_ref_mode: {ref_mode}\n')
    f.write(f'unw_ref_coh_threshold: ${UNW_REF_COH_THRESHOLD}\n')
    f.write(f'unw_reference_value_rad_subtracted: {ref_value}\n')
    f.write(f'unw_remove_plane: ${UNW_REMOVE_PLANE}\n')
    f.write(f'unw_plane_coeff_ax_by_c: {plane_coeff}\n')
    f.write(f'unw_output_apply_mask: ${UNW_OUTPUT_APPLY_MASK}\n')
    f.write(f'unw_output_coh_threshold: ${UNW_OUTPUT_COH_THRESHOLD}\n')
    f.write(f'unw_output_water_mask: ${UNW_OUTPUT_WATER_MASK}\n')
    f.write(f'valid_pixels_total: {unw.size}\n')
    f.write(f'reference_pixels: {int(np.count_nonzero(ref_ok))}\n')
    f.write(f'output_valid_pixels: {int(np.count_nonzero(out_ok))}\n')
    f.write(f'los_sign: ${LOS_SIGN}\n')
    f.write(f'wavelength_m: ${WAVELENGTH_M}\n')
    f.write(f'los_out_min_m: {los_min}\n')
    f.write(f'los_out_p01_m: {los_p01}\n')
    f.write(f'los_out_p50_m: {los_p50}\n')
    f.write(f'los_out_p99_m: {los_p99}\n')
    f.write(f'los_out_max_m: {los_max}\n')
print(f'Unwrapped phase raw written: ${DIFF0_ADF_UNW_RAW}')
print(f'Unwrapped phase reference-corrected written: ${DIFF0_ADF_UNW}')
print(f'LOS displacement, meters, written: ${DIFF0_ADF_LOS_M}')
print(f'Unwrap QC written: ${SNAPHU_QC}')
PY_POST_UNW
}


unwrap_if_requested(){
  if [[ "$DO_UNWRAP" -ne 1 || "$UNW_ENGINE" == "none" ]]; then
    log "DO_UNWRAP=0 or UNW_ENGINE=none; skip unwrapping"
    return 0
  fi

  case "$UNW_ENGINE" in
    snaphu|gamma_mcf|mk_unw_2d)
      unwrap_direct_engine
      return 0
      ;;
    mk_unw_2d_branch_cut)
      ;;
    *)
      echo "WARNING: unknown UNW_ENGINE=$UNW_ENGINE; skip unwrapping. Supported: none, snaphu, gamma_mcf, mk_unw_2d, mk_unw_2d_branch_cut" >&2
      return 0
      ;;
  esac

  if [[ "$FORCE_SNAPHU" -eq 0 && -s "$DIFF0_ADF_UNW" && -s "$DIFF0_ADF_LOS_M" ]]; then
    log "Reuse ${UNW_ENGINE} unwrap and LOS"
    return 0
  fi

  if ! command -v mk_unw_2d >/dev/null 2>&1; then
    echo "WARNING: mk_unw_2d command not found; skip mk_unw_2d NS-split unwrapping." >&2
    return 0
  fi
  if ! command -v geocode >/dev/null 2>&1; then
    echo "WARNING: geocode command not found; cannot build branch-cut side split masks." >&2
    return 0
  fi

  rm -f "$DIFF0_ADF_UNW" "$DIFF0_ADF_UNW_NATIVE" "$DIFF0_ADF_UNW_RAW" "$DIFF0_ADF_LOS_M" "$DIFF0_ADF_LOS_M_RAW" "$DIFF0_ADF_UNW_MASK" "$SNAPHU_QC" 2>/dev/null || true
  rm -rf "$MKUNW_DIR"
  mkdir -p "$MKUNW_DIR" "$NS_MASK_DIR"

  # Resolve manual branch-cut file. Do this inside the script so it can be run from any working directory.
  local branch_file=""
  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd)
  for cand in "$BRANCH_CUT_FILE" "$PWD/$BRANCH_CUT_FILE" "$WORKDIR/$BRANCH_CUT_FILE" "$PROJECT_ROOT/$BRANCH_CUT_FILE" "$ADF_DIR/$BRANCH_CUT_FILE" "$script_dir/$BRANCH_CUT_FILE"; do
    if [[ -s "$cand" ]]; then
      branch_file="$cand"
      break
    fi
  done
  if [[ -z "$branch_file" ]]; then
    echo "ERROR: manual branch-cut split requested but branch-cut file was not found: $BRANCH_CUT_FILE" >&2
    echo "Tried current directory, PWD, WORKDIR, PROJECT_ROOT, ADF_DIR, and script directory." >&2
    exit 1
  fi
  export BRANCH_FILE_RESOLVED="$branch_file"

  log "Build manual branch-cut side split masks from: $branch_file; buffer=${BRANCH_BUFFER_KM} km"

  # Build map-coordinate masks from the manual branch-cut polyline. The arbitrary left/right sign is
  # oriented so that the NORTH_REF_BOX belongs to the north side, if possible.
  python3 - <<PY_NS_MAP
import os, re, numpy as np, math
par_file=r'${LOOK_GEO_DIR}/EQA.rdc.dem_par'
out_dir=r'${NS_MASK_DIR}'
branch_file=os.environ['BRANCH_FILE_RESOLVED']

def read_par(fn):
    out={}
    pat=re.compile(r'^\s*(\S+):\s+([+-]?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)')
    with open(fn,'r',errors='ignore') as f:
        for line in f:
            m=pat.match(line)
            if m:
                k,v=m.group(1),m.group(2)
                out[k]=int(float(v)) if k in ['width','nlines'] else float(v)
    return out

def read_polyline_lonlat(fn):
    pts=[]
    with open(fn,'r',errors='ignore') as f:
        for line in f:
            line=line.strip()
            if not line or line.startswith('#') or line.startswith('>'):
                continue
            parts=re.split(r'[\s,]+', line)
            if len(parts) < 2:
                continue
            try:
                lon=float(parts[0]); lat=float(parts[1])
            except Exception:
                continue
            if np.isfinite(lon) and np.isfinite(lat):
                pts.append((lon,lat))
    if len(pts) < 2:
        raise RuntimeError(f'Branch-cut file has too few lon/lat points: {fn}')
    return np.asarray(pts, dtype=float)

p=read_par(par_file)
w,n=p['width'],p['nlines']
corner_lat,corner_lon=p['corner_lat'],p['corner_lon']
post_lat,post_lon=p['post_lat'],p['post_lon']
lons=corner_lon+np.arange(w)*post_lon
lats=corner_lat+np.arange(n)*post_lat
lon2,lat2=np.meshgrid(lons,lats)
pts=read_polyline_lonlat(branch_file)
blon=pts[:,0]; blat=pts[:,1]
# Equirectangular projection in km, sufficient for the narrow local branch-cut buffer.
lat0=float(np.nanmean(blat))
lon0=float(np.nanmean(blon))
km_per_deg_lat=111.32
km_per_deg_lon=111.32*math.cos(math.radians(lat0))
x=(lon2-lon0)*km_per_deg_lon
y=(lat2-lat0)*km_per_deg_lat
bx=(blon-lon0)*km_per_deg_lon
by=(blat-lat0)*km_per_deg_lat

# Nearest segment distance and signed side. Positive/negative is arbitrary and will be oriented by ref box.
dmin=np.full(x.shape, np.inf, dtype=np.float64)
side_sign=np.ones(x.shape, dtype=np.float64)
for i in range(len(bx)-1):
    x1,y1=bx[i],by[i]
    x2,y2=bx[i+1],by[i+1]
    dx=x2-x1; dy=y2-y1
    den=dx*dx+dy*dy
    if den <= 0:
        continue
    t=((x-x1)*dx+(y-y1)*dy)/den
    t=np.clip(t,0.0,1.0)
    px=x1+t*dx; py=y1+t*dy
    dd=np.hypot(x-px,y-py)
    sg=np.sign(dx*(y-y1)-dy*(x-x1))
    sg[sg==0]=1.0
    upd=dd < dmin
    dmin[upd]=dd[upd]
    side_sign[upd]=sg[upd]

buf=float('${BRANCH_BUFFER_KM}')
gap=(dmin <= buf)
side_pos=(side_sign >= 0)
side_neg=~side_pos

def box(lonmin,lonmax,latmin,latmax):
    return (lon2>=lonmin)&(lon2<=lonmax)&(lat2>=latmin)&(lat2<=latmax)

nbox=box(float('${NORTH_REF_LON_MIN}'),float('${NORTH_REF_LON_MAX}'),float('${NORTH_REF_LAT_MIN}'),float('${NORTH_REF_LAT_MAX}'))
sbox=box(float('${SOUTH_REF_LON_MIN}'),float('${SOUTH_REF_LON_MAX}'),float('${SOUTH_REF_LAT_MIN}'),float('${SOUTH_REF_LAT_MAX}'))
n_pos=int(np.count_nonzero(nbox & side_pos & (~gap)))
n_neg=int(np.count_nonzero(nbox & side_neg & (~gap)))
if int('${BRANCH_ORIENT_BY_REF_BOX}') == 1 and (n_pos+n_neg) > 0:
    north_side = side_pos if n_pos >= n_neg else side_neg
else:
    med_pos=np.nanmedian(lat2[side_pos & (~gap)]) if np.any(side_pos & (~gap)) else -999
    med_neg=np.nanmedian(lat2[side_neg & (~gap)]) if np.any(side_neg & (~gap)) else -999
    north_side = side_pos if med_pos >= med_neg else side_neg
south_side = ~north_side
north=north_side & (~gap)
south=south_side & (~gap)
nref=nbox & north
sref=sbox & south
for arr,fn in [(north,r'${NS_MAP_NORTH}'),(south,r'${NS_MAP_SOUTH}'),(gap,r'${NS_MAP_GAP}'),(nref,r'${NS_MAP_NORTH_REF}'),(sref,r'${NS_MAP_SOUTH_REF}')]:
    arr.astype('>f4').tofile(fn)
map_lon_min=float(np.nanmin(lon2)); map_lon_max=float(np.nanmax(lon2))
map_lat_min=float(np.nanmin(lat2)); map_lat_max=float(np.nanmax(lat2))
def edge_dist_km(lon, lat):
    dx=min(abs(lon-map_lon_min), abs(lon-map_lon_max))*km_per_deg_lon
    dy=min(abs(lat-map_lat_min), abs(lat-map_lat_max))*km_per_deg_lat
    return float(min(dx, dy))
with open(r'${NS_SPLIT_QC}','w') as f:
    f.write('ns_split_strategy: manual_branch_cut_side_split_no_join_buffer\n')
    f.write(f'branch_cut_file: {branch_file}\n')
    f.write(f'branch_buffer_km: {buf}\n')
    f.write(f'branch_num_points: {len(blon)}\n')
    f.write(f'map_grid_shape: {n} {w}\n')
    f.write(f'map_lon_range: {map_lon_min} {map_lon_max}\n')
    f.write(f'map_lat_range: {map_lat_min} {map_lat_max}\n')
    f.write(f'branch_lon_range: {float(np.nanmin(blon))} {float(np.nanmax(blon))}\n')
    f.write(f'branch_lat_range: {float(np.nanmin(blat))} {float(np.nanmax(blat))}\n')
    f.write(f'branch_start_lonlat: {float(blon[0])} {float(blat[0])}\n')
    f.write(f'branch_end_lonlat: {float(blon[-1])} {float(blat[-1])}\n')
    f.write(f'branch_start_edge_distance_km: {edge_dist_km(float(blon[0]), float(blat[0]))}\n')
    f.write(f'branch_end_edge_distance_km: {edge_dist_km(float(blon[-1]), float(blat[-1]))}\n')
    f.write(f'orientation_north_ref_pos_pixels: {n_pos}\n')
    f.write(f'orientation_north_ref_neg_pixels: {n_neg}\n')
    f.write(f'map_north_pixels: {int(north.sum())}\n')
    f.write(f'map_south_pixels: {int(south.sum())}\n')
    f.write(f'map_gap_pixels: {int(gap.sum())}\n')
    f.write(f'north_ref_box: ${NORTH_REF_LON_MIN} ${NORTH_REF_LON_MAX} ${NORTH_REF_LAT_MIN} ${NORTH_REF_LAT_MAX}\n')
    f.write(f'south_ref_box: ${SOUTH_REF_LON_MIN} ${SOUTH_REF_LON_MAX} ${SOUTH_REF_LAT_MIN} ${SOUTH_REF_LAT_MAX}\n')
print('[NS] Wrote manual branch-cut side masks in', out_dir)
PY_NS_MAP

  # Geocode map masks to radar coordinates.  Nearest-neighbor-like interpolation is used.
  (
    cd "$LOOK_GEO_DIR"
    for f in "$NS_MAP_NORTH" "$NS_MAP_SOUTH" "$NS_MAP_GAP" "$NS_MAP_NORTH_REF" "$NS_MAP_SOUTH_REF"; do
      ln -sf "$f" .
    done
    geocode "${PAIR}_${LOOK}.lt_fine" "$(basename "$NS_MAP_NORTH")"     "$MAP_WIDTH" "$NS_RDC_NORTH"     "$R_WIDTH" "$INT_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_ns_north_to_radar.log" 2>&1
    geocode "${PAIR}_${LOOK}.lt_fine" "$(basename "$NS_MAP_SOUTH")"     "$MAP_WIDTH" "$NS_RDC_SOUTH"     "$R_WIDTH" "$INT_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_ns_south_to_radar.log" 2>&1
    geocode "${PAIR}_${LOOK}.lt_fine" "$(basename "$NS_MAP_GAP")"       "$MAP_WIDTH" "$NS_RDC_GAP"       "$R_WIDTH" "$INT_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_ns_gap_to_radar.log" 2>&1
    geocode "${PAIR}_${LOOK}.lt_fine" "$(basename "$NS_MAP_NORTH_REF")" "$MAP_WIDTH" "$NS_RDC_NORTH_REF" "$R_WIDTH" "$INT_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_ns_north_ref_to_radar.log" 2>&1
    geocode "${PAIR}_${LOOK}.lt_fine" "$(basename "$NS_MAP_SOUTH_REF")" "$MAP_WIDTH" "$NS_RDC_SOUTH_REF" "$R_WIDTH" "$INT_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_ns_south_ref_to_radar.log" 2>&1
  )

  # Convert radar-coordinate region masks into BMP masks for mk_unw_2d/mcf.
  # Important: mk_unw_2d applies MKUNW_NLKS internally before calling mcf.
  # Therefore a user-supplied mask must have dimensions width/MKUNW_NLKS x lines/MKUNW_NLKS,
  # not the original interferogram dimensions.  Keep full-resolution masks for final merging,
  # but write downsampled BMP masks for mk_unw_2d.
  python3 - <<PY_NS_BMP
import os, struct, numpy as np
w=int('${R_WIDTH}')
nlks=int('${MKUNW_NLKS}')
phase=np.fromfile(r'${DIFF0_ADF_PHASE}', dtype='>f4')
cc=np.fromfile(r'${DIFF0_ADF_CC}', dtype='>f4')
if phase.size % w != 0:
    raise RuntimeError(f'phase size {phase.size} not divisible by width {w}')
n=phase.size//w
shape=(n,w)
cc=cc.reshape(shape)
north=np.fromfile(r'${NS_RDC_NORTH}', dtype='>f4').reshape(shape) >= 0.5
south=np.fromfile(r'${NS_RDC_SOUTH}', dtype='>f4').reshape(shape) >= 0.5
gap=np.fromfile(r'${NS_RDC_GAP}', dtype='>f4').reshape(shape) >= 0.5
hgt=None
if os.path.exists(r'${HGT}') and os.path.getsize(r'${HGT}')>0:
    h=np.fromfile(r'${HGT}', dtype='>f4')
    if h.size==phase.size:
        hgt=h.reshape(shape)
land=np.ones(shape,dtype=bool)
if int('${NS_MASK_WATER}')==1 and hgt is not None:
    land &= np.isfinite(hgt) & (hgt > float('${UNW_OUTPUT_WATER_THRESHOLD}'))
coh_ok=np.isfinite(cc) & (cc >= float('${UNW_COH_THRESHOLD}'))
valid_n_full=north & (~gap) & land & coh_ok
valid_s_full=south & (~gap) & land & coh_ok
# Full-resolution masks are used later to merge the full-resolution output.
np.asarray(valid_n_full,dtype='>f4').tofile(r'${NS_RDC_NORTH_VALID}')
np.asarray(valid_s_full,dtype='>f4').tofile(r'${NS_RDC_SOUTH_VALID}')

def downsample_bool(mask, nlks):
    if nlks <= 1:
        return np.asarray(mask, dtype=bool)
    h2 = mask.shape[0] // nlks
    w2 = mask.shape[1] // nlks
    if h2 <= 0 or w2 <= 0:
        raise RuntimeError(f'Invalid downsample dimensions for mask shape={mask.shape}, nlks={nlks}')
    cropped = np.asarray(mask[:h2*nlks, :w2*nlks], dtype=bool)
    # A coarse pixel is valid if any original pixel in the block is valid.  This preserves
    # region connectivity; the coherence grid cc2 is still used as the MCF weight.
    return cropped.reshape(h2, nlks, w2, nlks).any(axis=(1,3))

valid_n_mcf = downsample_bool(valid_n_full, nlks)
valid_s_mcf = downsample_bool(valid_s_full, nlks)

def write_bmp_mask(fn, mask):
    # 8-bit paletted BMP, bottom-up rows. Nonzero pixels are valid for GAMMA mcf masks.
    mask=np.asarray(mask, dtype=np.uint8)*255
    height,width=mask.shape
    row_bytes=((width+3)//4)*4
    pad=row_bytes-width
    palette=b''.join(bytes([i,i,i,0]) for i in range(256))
    pixel_offset=14+40+len(palette)
    img_size=row_bytes*height
    file_size=pixel_offset+img_size
    with open(fn,'wb') as f:
        f.write(b'BM')
        f.write(struct.pack('<IHHI', file_size, 0, 0, pixel_offset))
        f.write(struct.pack('<IiiHHIIiiII', 40, width, height, 1, 8, 0, img_size, 2835, 2835, 256, 256))
        f.write(palette)
        for row in mask[::-1,:]:
            f.write(row.tobytes())
            if pad:
                f.write(b'\x00'*pad)
write_bmp_mask(r'${NS_BMP_NORTH}', valid_n_mcf)
write_bmp_mask(r'${NS_BMP_SOUTH}', valid_s_mcf)
with open(r'${NS_SPLIT_QC}','a') as f:
    f.write(f'radar_grid_shape: {n} {w}\n')
    f.write(f'mkunw_nlks_for_mask: {nlks}\n')
    f.write(f'mcf_mask_grid_shape: {valid_n_mcf.shape[0]} {valid_n_mcf.shape[1]}\n')
    f.write(f'radar_north_region_pixels: {int(north.sum())}\n')
    f.write(f'radar_south_region_pixels: {int(south.sum())}\n')
    f.write(f'radar_gap_pixels: {int(gap.sum())}\n')
    f.write(f'radar_north_valid_pixels_fullres: {int(valid_n_full.sum())}\n')
    f.write(f'radar_south_valid_pixels_fullres: {int(valid_s_full.sum())}\n')
    f.write(f'mcf_north_valid_pixels_downsampled: {int(valid_n_mcf.sum())}\n')
    f.write(f'mcf_south_valid_pixels_downsampled: {int(valid_s_mcf.sum())}\n')
    f.write(f'valid_mask_coh_threshold: ${UNW_COH_THRESHOLD}\n')
    f.write(f'valid_mask_water: ${NS_MASK_WATER}\n')
minpix=int('${NS_MIN_REGION_PIXELS}')
if valid_n_full.sum() < minpix or valid_s_full.sum() < minpix:
    raise RuntimeError(f'North/south valid pixels too few: north={valid_n_full.sum()} south={valid_s_full.sum()} min={minpix}. See {r"${NS_SPLIT_QC}"}')
if valid_n_mcf.sum() < max(10, minpix//(nlks*nlks)) or valid_s_mcf.sum() < max(10, minpix//(nlks*nlks)):
    raise RuntimeError(f'Downsampled MCF mask pixels too few: north={valid_n_mcf.sum()} south={valid_s_mcf.sum()}. See {r"${NS_SPLIT_QC}"}')
print('[NS] BMP masks written for mk_unw_2d/mcf:', r'${NS_BMP_NORTH}', r'${NS_BMP_SOUTH}', 'shape=', valid_n_mcf.shape)
PY_NS_BMP

  run_mkunw_region(){
    local side="$1" mask_bmp="$2" region_dir="$3" out_native="$4"
    local region_diff_dir="${region_dir}/diff"
    local region_rslc_tab="${region_dir}/${PAIR}_${LOOK}.${side}.RSLC_tab"
    local region_itab="${region_dir}/${PAIR}_${LOOK}.${side}.itab"
    local region_log="${ADF_LOG_DIR}/mk_unw_2d.${side}.log"
    local region_out_list="${region_dir}/mk_unw_2d_outputs.txt"
    local mk_pair="${REF}_${SEC}"
    mkdir -p "$region_diff_dir"

    local mk_ref_slc="${region_dir}/${REF}.rslc"
    local mk_ref_par="${region_dir}/${REF}.rslc.par"
    local mk_sec_slc="${region_dir}/${SEC}.rslc"
    local mk_sec_par="${region_dir}/${SEC}.rslc.par"
    ln -sf "$REF_MOSAIC"     "$mk_ref_slc"
    ln -sf "$REF_MOSAIC_PAR" "$mk_ref_par"
    ln -sf "$SEC_MOSAIC"     "$mk_sec_slc"
    ln -sf "$SEC_MOSAIC_PAR" "$mk_sec_par"
    ln -sf "$OFF_LOOK"       "$region_diff_dir/${mk_pair}.off"
    ln -sf "$DIFF0"          "$region_diff_dir/${mk_pair}.diff"
    ln -sf "$DIFF0_ADF"      "$region_diff_dir/${mk_pair}.adf.diff"
    ln -sf "$DIFF0_ADF_CC"   "$region_diff_dir/${mk_pair}.adf.cc"
    ln -sf "$DIFF0_ADF_CC"   "$region_diff_dir/${mk_pair}.cc"
    printf "%s %s\n%s %s\n" "$mk_ref_slc" "$mk_ref_par" "$mk_sec_slc" "$mk_sec_par" > "$region_rslc_tab"
    printf "1 2 1 1\n" > "$region_itab"
    {
      echo "side=$side"
      echo "region_dir=$region_dir"
      echo "region_diff_dir=$region_diff_dir"
      echo "mask_bmp=$mask_bmp"
      echo "Command: mk_unw_2d $region_rslc_tab $region_itab $REF_MLI $region_diff_dir $MKUNW_CC_THRES $MKUNW_PWR_THRES $MKUNW_NLKS $MKUNW_NPAT_R $MKUNW_NPAT_AZ $MKUNW_MODE $MKUNW_R_INIT $MKUNW_AZ_INIT $MKUNW_TRI_MODE $mask_bmp $MKUNW_ROFF $MKUNW_LOFF $MKUNW_NR $MKUNW_NLINES"
      ls -lh "$mask_bmp" "$region_diff_dir/${mk_pair}.off" "$region_diff_dir/${mk_pair}.adf.diff" "$region_diff_dir/${mk_pair}.adf.cc" 2>/dev/null || true
    } > "${ADF_LOG_DIR}/mk_unw_2d.${side}.inputs.log"

    set +e
    mk_unw_2d "$region_rslc_tab" "$region_itab" "$REF_MLI" "$region_diff_dir" \
      "$MKUNW_CC_THRES" "$MKUNW_PWR_THRES" "$MKUNW_NLKS" "$MKUNW_NPAT_R" "$MKUNW_NPAT_AZ" "$MKUNW_MODE" \
      "$MKUNW_R_INIT" "$MKUNW_AZ_INIT" "$MKUNW_TRI_MODE" "$mask_bmp" "$MKUNW_ROFF" "$MKUNW_LOFF" "$MKUNW_NR" "$MKUNW_NLINES" \
      > "$region_log" 2>&1
    local status_mkunw=$?
    set -e
    find "$region_diff_dir" -maxdepth 1 -type f \( -name "*.unw" -o -name "*.unw0" -o -name "*.unw*" \) -printf "%T@ %s %p\n" | sort -n > "$region_out_list" || true
    if [[ $status_mkunw -ne 0 ]]; then
      echo "WARNING: mk_unw_2d $side returned non-zero status: $status_mkunw" >&2
      echo "Check: $region_log and ${ADF_LOG_DIR}/mk_unw_2d.${side}.inputs.log" >&2
      return 1
    fi
    PHASE_FILE_FOR_PICK="$DIFF0_ADF_PHASE" REGION_DIFF_DIR="$region_diff_dir" REGION_OUT_LIST="$region_out_list" REGION_DIR="$region_dir" REGION_OUT_NATIVE="$out_native" python3 - <<'PY_PICK'
import os, glob, numpy as np
phase_file=os.environ.get('PHASE_FILE_FOR_PICK') or r'${DIFF0_ADF_PHASE}'
phase=np.fromfile(phase_file, dtype='>f4')
expected_bytes=phase.size*4
diff_dir=os.environ['REGION_DIFF_DIR']; out_list=os.environ['REGION_OUT_LIST']
all_files=[]
for pat in ('*.unw','*.unw0','*.unw*'):
    all_files.extend(glob.glob(os.path.join(diff_dir, pat)))
seen=[]
for f in all_files:
    if f not in seen:
        seen.append(f)
def is_display(fn):
    return fn.lower().endswith(('.bmp','.ras','.tif','.tiff','.png','.jpg','.jpeg'))
candidates=[]
with open(out_list,'a') as fo:
    fo.write('\n[python selector] expected_float_bytes=%d expected_pixels=%d\n' % (expected_bytes, phase.size))
    for f in sorted(seen, key=lambda x: os.path.getmtime(x)):
        sz=os.path.getsize(f)
        fo.write('[python selector] file=%s bytes=%d display=%s\n' % (f, sz, is_display(f)))
        if (not is_display(f)) and sz == expected_bytes:
            candidates.append(f)
if not candidates:
    raise RuntimeError('mk_unw_2d produced no binary float *.unw file with expected size. See '+out_list)
src=sorted(candidates, key=lambda x: os.path.getmtime(x))[-1]
cands=[]
for dt in ['>f4','<f4']:
    arr=np.fromfile(src,dtype=dt)
    finite=np.isfinite(arr)&np.isfinite(phase)
    if finite.any():
        d=np.angle(np.exp(1j*(arr[finite].astype(np.float64)-phase[finite].astype(np.float64))))
        med=float(np.nanmedian(np.abs(d)))
    else:
        med=float('inf')
    cands.append((med,dt,arr))
med,dt,arr=sorted(cands,key=lambda x:x[0])[0]
arr.astype(np.float32).tofile(os.environ['REGION_OUT_NATIVE'])
with open(os.path.join(os.environ['REGION_DIR'],'selected_unw_output.txt'),'w') as f:
    f.write(src+'\n')
    f.write(f'dtype={dt}\n')
    f.write(f'median_wrap_unw_minus_phase={med}\n')
print('[MK_UNW_2D_NS] selected', src, 'dtype', dt, 'median', med)
PY_PICK
  }

  local north_dir="${MKUNW_DIR}/north"
  local south_dir="${MKUNW_DIR}/south"
  local north_native="${north_dir}/${PAIR}_${LOOK}.${UNW_TAG}.north.unw.native"
  local south_native="${south_dir}/${PAIR}_${LOOK}.${UNW_TAG}.south.unw.native"

  log "Run mk_unw_2d independently for NORTH"
  run_mkunw_region "north" "$NS_BMP_NORTH" "$north_dir" "$north_native"
  log "Run mk_unw_2d independently for SOUTH"
  run_mkunw_region "south" "$NS_BMP_SOUTH" "$south_dir" "$south_native"

  log "Combine north/south unwrapped phases with side-wise far-field zero"
  python3 - <<PY_COMBINE
import os, numpy as np, math
w=int('${R_WIDTH}')
phase=np.fromfile(r'${DIFF0_ADF_PHASE}', dtype='>f4')
cc=np.fromfile(r'${DIFF0_ADF_CC}', dtype='>f4')
if phase.size % w != 0:
    raise RuntimeError('phase size not divisible by width')
n=phase.size//w; shape=(n,w)
phase2=phase.reshape(shape); cc2=cc.reshape(shape)
N=np.fromfile(r'$north_native', dtype=np.float32).reshape(shape).astype(np.float64)
S=np.fromfile(r'$south_native', dtype=np.float32).reshape(shape).astype(np.float64)
validN=np.fromfile(r'${NS_RDC_NORTH_VALID}', dtype='>f4').reshape(shape) >= 0.5
validS=np.fromfile(r'${NS_RDC_SOUTH_VALID}', dtype='>f4').reshape(shape) >= 0.5
refN=np.fromfile(r'${NS_RDC_NORTH_REF}', dtype='>f4').reshape(shape) >= 0.5
refS=np.fromfile(r'${NS_RDC_SOUTH_REF}', dtype='>f4').reshape(shape) >= 0.5
ref_coh=float('${NS_REF_COH_THRESHOLD}')
refN_ok=validN & refN & np.isfinite(N) & np.isfinite(cc2) & (cc2>=ref_coh)
refS_ok=validS & refS & np.isfinite(S) & np.isfinite(cc2) & (cc2>=ref_coh)
min_ref=int('${NS_MIN_REF_PIXELS}')
fallbackN=False; fallbackS=False
if np.count_nonzero(refN_ok) < min_ref:
    fallbackN=True
    refN_ok=validN & np.isfinite(N) & np.isfinite(cc2) & (cc2>=ref_coh)
if np.count_nonzero(refS_ok) < min_ref:
    fallbackS=True
    refS_ok=validS & np.isfinite(S) & np.isfinite(cc2) & (cc2>=ref_coh)
if np.count_nonzero(refN_ok) < min_ref or np.count_nonzero(refS_ok) < min_ref:
    raise RuntimeError(f'too few NS reference pixels after fallback: north={np.count_nonzero(refN_ok)} south={np.count_nonzero(refS_ok)} min={min_ref}. Tune reference boxes or threshold.')
refN_val=float(np.nanmedian(N[refN_ok]))
refS_val=float(np.nanmedian(S[refS_ok]))
raw=np.full(shape, np.nan, dtype=np.float64)
out=np.full(shape, np.nan, dtype=np.float64)
raw[validN]=N[validN]
raw[validS]=S[validS]
out[validN]=N[validN]-refN_val
out[validS]=S[validS]-refS_val
# Raw wrap diagnostic, before reference shifts.
d=np.angle(np.exp(1j*(raw-phase2)))
valid_d=np.isfinite(d) & (validN | validS)
med_abs=float(np.nanmedian(np.abs(d[valid_d]))) if valid_d.any() else float('nan')
p90,p99=(np.nanpercentile(np.abs(d[valid_d]),[90,99]).tolist() if valid_d.any() else [float('nan'),float('nan')])
raw.astype(np.float32).tofile(r'${NS_COMBINED_RAW_NATIVE}')
out.astype(np.float32).tofile(r'${DIFF0_ADF_UNW_NATIVE}')
with open(r'${NS_SPLIT_QC}','a') as f:
    f.write('combine_status: success\n')
    f.write(f'north_ref_pixels: {int(np.count_nonzero(refN_ok))}\n')
    f.write(f'south_ref_pixels: {int(np.count_nonzero(refS_ok))}\n')
    f.write(f'north_ref_fallback_to_region: {int(fallbackN)}\n')
    f.write(f'south_ref_fallback_to_region: {int(fallbackS)}\n')
    f.write(f'north_ref_value_rad_subtracted: {refN_val}\n')
    f.write(f'south_ref_value_rad_subtracted: {refS_val}\n')
    f.write(f'combined_valid_north_pixels: {int(np.count_nonzero(validN))}\n')
    f.write(f'combined_valid_south_pixels: {int(np.count_nonzero(validS))}\n')
    f.write(f'raw_wrap_unw_minus_phase_median_abs_rad: {med_abs}\n')
    f.write(f'raw_wrap_unw_minus_phase_p90_abs_rad: {p90}\n')
    f.write(f'raw_wrap_unw_minus_phase_p99_abs_rad: {p99}\n')
print('[NS] Combined output written:', r'${DIFF0_ADF_UNW_NATIVE}')
PY_COMBINE

  python3 - <<PY_POST_UNW
import numpy as np, math, os
w = int('${R_WIDTH}')
phase = np.fromfile('${DIFF0_ADF_PHASE}', dtype='>f4')
cc = np.fromfile('${DIFF0_ADF_CC}', dtype='>f4')
unw_native = np.fromfile('${DIFF0_ADF_UNW_NATIVE}', dtype=np.float32)
if unw_native.size != phase.size:
    raise RuntimeError(f'unwrapped size mismatch: {unw_native.size} vs phase {phase.size}')
shape = (-1, w)
phase2 = phase.reshape(shape)
cc2 = cc.reshape(shape)
unw = unw_native.reshape(shape).astype(np.float64)
# Reference has already been applied side-wise.  Do not subtract a global value here.
unw_corr = unw.copy()
d = np.angle(np.exp(1j*(np.fromfile('${NS_COMBINED_RAW_NATIVE}', dtype=np.float32).reshape(shape).astype(np.float64) - phase2)))
valid_d = np.isfinite(d)
med_abs = float(np.nanmedian(np.abs(d[valid_d]))) if valid_d.any() else float('nan')
p90, p99 = (np.nanpercentile(np.abs(d[valid_d]), [90, 99]).tolist() if valid_d.any() else [float('nan'), float('nan')])
hgt_file='${HGT}'
hgt = None
if os.path.exists(hgt_file) and os.path.getsize(hgt_file) > 0:
    h = np.fromfile(hgt_file, dtype='>f4')
    if h.size == phase.size:
        hgt = h.reshape(shape)
land_ok = np.ones_like(cc2, dtype=bool)
if int('${UNW_OUTPUT_WATER_MASK}') == 1 and hgt is not None:
    land_ok &= np.isfinite(hgt) & (hgt > float('${UNW_OUTPUT_WATER_THRESHOLD}'))
out_ok = np.isfinite(unw_corr) & np.isfinite(cc2) & land_ok
if int('${UNW_OUTPUT_APPLY_MASK}') == 1:
    out_ok &= (cc2 >= float('${UNW_OUTPUT_COH_THRESHOLD}'))
unw_raw = np.fromfile('${NS_COMBINED_RAW_NATIVE}', dtype=np.float32).reshape(shape)
los_raw = float('${LOS_SIGN}') * unw_raw * float('${WAVELENGTH_M}') / (4.0*math.pi)
unw_out = unw_corr.astype(np.float32)
los_out = float('${LOS_SIGN}') * unw_out * float('${WAVELENGTH_M}') / (4.0*math.pi)
if int('${UNW_OUTPUT_APPLY_MASK}') == 1:
    unw_out[~out_ok] = np.nan
    los_out[~out_ok] = np.nan
valid_los = np.isfinite(los_out)
if valid_los.any():
    los_min = float(np.nanmin(los_out[valid_los]))
    los_p01, los_p50, los_p99 = [float(x) for x in np.nanpercentile(los_out[valid_los], [1, 50, 99])]
    los_max = float(np.nanmax(los_out[valid_los]))
else:
    los_min = los_p01 = los_p50 = los_p99 = los_max = float('nan')
unw_raw.astype('>f4').tofile('${DIFF0_ADF_UNW_RAW}')
los_raw.astype('>f4').tofile('${DIFF0_ADF_LOS_M_RAW}')
unw_out.astype('>f4').tofile('${DIFF0_ADF_UNW}')
los_out.astype('>f4').tofile('${DIFF0_ADF_LOS_M}')
out_ok.astype(np.uint8).tofile('${DIFF0_ADF_UNW_MASK}')
with open('${SNAPHU_QC}', 'w') as f:
    f.write(f'unwrap_engine: ${UNW_ENGINE}\n')
    f.write(f'unwrap_tag: ${UNW_TAG}\n')
    f.write(f'branch_cut_file_used: ${BRANCH_CUT_FILE}\n')
    f.write(f'branch_buffer_km: ${BRANCH_BUFFER_KM}\n')
    f.write('ns_split_lat: not_used_manual_branch_cut_split\n')
    f.write('ns_split_buffer_deg: not_used_manual_branch_cut_split\n')
    f.write(f'mkunw_cc_thres: ${MKUNW_CC_THRES}\n')
    f.write(f'mkunw_pwr_thres: ${MKUNW_PWR_THRES}\n')
    f.write(f'mkunw_nlks: ${MKUNW_NLKS}\n')
    f.write(f'mkunw_npat_r: ${MKUNW_NPAT_R}\n')
    f.write(f'mkunw_npat_az: ${MKUNW_NPAT_AZ}\n')
    f.write(f'mkunw_mode: ${MKUNW_MODE}\n')
    f.write(f'raw_wrap_unw_minus_phase_median_abs_rad: {med_abs}\n')
    f.write(f'raw_wrap_unw_minus_phase_p90_abs_rad: {p90}\n')
    f.write(f'raw_wrap_unw_minus_phase_p99_abs_rad: {p99}\n')
    f.write('unw_ref_mode: sidewise_box\n')
    f.write(f'ns_ref_coh_threshold: ${NS_REF_COH_THRESHOLD}\n')
    f.write(f'unw_output_apply_mask: ${UNW_OUTPUT_APPLY_MASK}\n')
    f.write(f'unw_output_coh_threshold: ${UNW_OUTPUT_COH_THRESHOLD}\n')
    f.write(f'unw_output_water_mask: ${UNW_OUTPUT_WATER_MASK}\n')
    f.write(f'valid_pixels_total: {unw.size}\n')
    f.write(f'output_valid_pixels: {int(np.count_nonzero(out_ok))}\n')
    f.write(f'los_sign: ${LOS_SIGN}\n')
    f.write(f'wavelength_m: ${WAVELENGTH_M}\n')
    f.write(f'los_out_min_m: {los_min}\n')
    f.write(f'los_out_p01_m: {los_p01}\n')
    f.write(f'los_out_p50_m: {los_p50}\n')
    f.write(f'los_out_p99_m: {los_p99}\n')
    f.write(f'los_out_max_m: {los_max}\n')
print(f'NS-split raw unwrapped phase written: ${DIFF0_ADF_UNW_RAW}')
print(f'NS-split side-wise referenced unwrapped phase written: ${DIFF0_ADF_UNW}')
print(f'NS-split LOS displacement, meters, written: ${DIFF0_ADF_LOS_M}')
print(f'Unwrap QC written: ${SNAPHU_QC}')
PY_POST_UNW
  cat "$NS_SPLIT_QC" >> "$SNAPHU_QC" || true
}

geocode_outputs(){
  mkdir -p "$ADF_GEO_DIR"
  cd "$ADF_GEO_DIR"
  ln -sf "$DIFF0_PHASE" .
  ln -sf "$DIFF0_ADF_PHASE" .
  ln -sf "$DIFF0_ADF_CC" .
  [[ -s "$DIFF0_ADF_UNW" ]] && ln -sf "$DIFF0_ADF_UNW" .
  [[ -s "$DIFF0_ADF_LOS_M" ]] && ln -sf "$DIFF0_ADF_LOS_M" .
  ln -sf "${LOOK_GEO_DIR}/EQA.rdc.dem_par" EQA.rdc.dem_par
  ln -sf "${LOOK_GEO_DIR}/EQA.rdc.dem" EQA.rdc.dem
  ln -sf "${LOOK_GEO_DIR}/${PAIR}_${LOOK}.lt_fine" .

  MAP_WIDTH=$(awk '$1=="width:" {print $2}' EQA.rdc.dem_par)
  MAP_LINES=$(awk '$1=="nlines:" {print $2}' EQA.rdc.dem_par)
  export MAP_WIDTH MAP_LINES

  local lt="${PAIR}_${LOOK}.lt_fine"
  local phase0="$(basename "$DIFF0_PHASE")"
  local phase_adf="$(basename "$DIFF0_ADF_PHASE")"
  local cc_adf="$(basename "$DIFF0_ADF_CC")"
  local unw_adf="$(basename "$DIFF0_ADF_UNW")"
  local los_m="$(basename "$DIFF0_ADF_LOS_M")"

  if [[ "$FORCE_ADF" -eq 1 ]]; then
    rm -f "EQA.${phase_adf}" "EQA.${cc_adf}" "EQA.${unw_adf}" "EQA.${los_m}"
  fi
  if [[ "$FORCE_SNAPHU" -eq 1 ]]; then
    rm -f "EQA.${unw_adf}" "EQA.${los_m}"
  fi

  if [[ ! -s "EQA.${phase0}" ]]; then
    geocode_back "$phase0" "$R_WIDTH" "$lt" "EQA.${phase0}" "$MAP_WIDTH" "$MAP_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_back.phase0.log" 2>&1
  fi
  if [[ ! -s "EQA.${phase_adf}" ]]; then
    geocode_back "$phase_adf" "$R_WIDTH" "$lt" "EQA.${phase_adf}" "$MAP_WIDTH" "$MAP_LINES" 0 0 > "${ADF_LOG_DIR}/geocode_back.phase_adf.log" 2>&1
  fi
  if [[ ! -s "EQA.${cc_adf}" ]]; then
    geocode_back "$cc_adf" "$R_WIDTH" "$lt" "EQA.${cc_adf}" "$MAP_WIDTH" "$MAP_LINES" 2 0 > "${ADF_LOG_DIR}/geocode_back.cc_adf.log" 2>&1
  fi
  if [[ -s "$unw_adf" && ! -s "EQA.${unw_adf}" ]]; then
    geocode_back "$unw_adf" "$R_WIDTH" "$lt" "EQA.${unw_adf}" "$MAP_WIDTH" "$MAP_LINES" "$GEOCODE_UNW_INTERP" 0 > "${ADF_LOG_DIR}/geocode_back.unw_adf.log" 2>&1 || true
  fi
  if [[ -s "$los_m" && ! -s "EQA.${los_m}" ]]; then
    geocode_back "$los_m" "$R_WIDTH" "$lt" "EQA.${los_m}" "$MAP_WIDTH" "$MAP_LINES" "$GEOCODE_UNW_INTERP" 0 > "${ADF_LOG_DIR}/geocode_back.los_m.log" 2>&1 || true
  fi

  cd "$ADF_DIR"
}

check_geocode_edge_clipping(){
  [[ "${GEOCODE_EDGE_QC}" -eq 1 ]] || return 0
  local report="${ADF_GEO_DIR}/GEOCODE_EXTENT_QC.txt"
  local cc_geo="${ADF_GEO_DIR}/EQA.$(basename "$DIFF0_ADF_CC")"
  [[ -s "$cc_geo" ]] || { echo "[GEOCODE] extent QC skipped: geocoded coherence not found: $cc_geo" >&2; return 0; }

  set +e
  DEM_PAR_QC="$DEM_PAR" MAP_PAR_QC="${ADF_GEO_DIR}/EQA.rdc.dem_par" CC_QC="$cc_geo" \
  BAND_QC="$GEOCODE_EDGE_BAND_PIXELS" FRAC_QC="$GEOCODE_EDGE_VALID_FRACTION" EPS_QC="$GEOCODE_EDGE_CC_EPS" \
  REPORT_QC="$report" python3 - <<'PY_EDGE_QC'
import os,re,sys,numpy as np

def par(path):
    d={}
    with open(path,errors='ignore') as f:
        for line in f:
            m=re.match(r'^\s*(\S+):\s+([+-]?[0-9.eE+-]+)',line)
            if m:
                try:d[m.group(1)]=float(m.group(2))
                except:pass
    return d

def bounds(d):
    w=int(d['width']); n=int(d['nlines'])
    x0=d['corner_lon']; x1=x0+(w-1)*d['post_lon']
    y0=d['corner_lat']; y1=y0+(n-1)*d['post_lat']
    return min(x0,x1),max(x0,x1),min(y0,y1),max(y0,y1),w,n

dp=par(os.environ['DEM_PAR_QC']); mp=par(os.environ['MAP_PAR_QC'])
required={'corner_lon','corner_lat','post_lon','post_lat','width','nlines'}
if not required.issubset(dp) or not required.issubset(mp):
    print('[GEOCODE] extent QC skipped: incomplete DEM/map parameter metadata',file=sys.stderr); sys.exit(0)
dw,de,ds,dn,dwidth,dlines=bounds(dp)
mw,me,ms,mn,mwidth,mlines=bounds(mp)
a=np.fromfile(os.environ['CC_QC'],dtype='>f4')
need=mwidth*mlines
if a.size < need:
    print(f'[GEOCODE] extent QC skipped: coherence size {a.size} < {need}',file=sys.stderr); sys.exit(0)
a=a[:need].reshape(mlines,mwidth)
band=max(1,min(int(os.environ['BAND_QC']),mwidth//2,mlines//2))
eps=float(os.environ['EPS_QC']); minfrac=float(os.environ['FRAC_QC'])
valid=np.isfinite(a)&(a>eps)
fractions={
 'west':float(valid[:,:band].mean()), 'east':float(valid[:,-band:].mean()),
 'north':float(valid[:band,:].mean()), 'south':float(valid[-band:,:].mean())}
tol_lon=max(abs(dp['post_lon']),abs(mp['post_lon']))*2.1
tol_lat=max(abs(dp['post_lat']),abs(mp['post_lat']))*2.1
same={'west':abs(mw-dw)<=tol_lon,'east':abs(me-de)<=tol_lon,
      'south':abs(ms-ds)<=tol_lat,'north':abs(mn-dn)<=tol_lat}
clipped=[k for k in ('west','east','south','north') if same[k] and fractions[k]>=minfrac]
with open(os.environ['REPORT_QC'],'w') as f:
    f.write(f'dem_lon_extent: {dw} {de}\ndem_lat_extent: {ds} {dn}\n')
    f.write(f'map_lon_extent: {mw} {me}\nmap_lat_extent: {ms} {mn}\n')
    f.write(f'map_shape: {mlines} {mwidth}\nedge_band_pixels: {band}\n')
    for k in ('west','east','south','north'):
        f.write(f'{k}_matches_dem_edge: {int(same[k])}\n{k}_valid_fraction: {fractions[k]:.8f}\n')
    f.write('suspected_dem_clipped_edges: '+(' '.join(clipped) if clipped else 'none')+'\n')
print(f'[GEOCODE] output map extent: lon={mw:.8f}..{me:.8f}, lat={ms:.8f}..{mn:.8f}, shape={mlines}x{mwidth}')
print('[GEOCODE] edge valid fractions: '+', '.join(f'{k}={fractions[k]:.4f}' for k in ('west','east','south','north')))
if clipped:
    print('[GEOCODE] suspected clipping by source DEM edge(s): '+', '.join(clipped),file=sys.stderr)
    sys.exit(42)
PY_EDGE_QC
  local st=$?
  set -e
  if [[ $st -eq 42 ]]; then
    echo "[GEOCODE] The geocoded scene reaches a boundary of the input DEM while valid data continue to that edge." >&2
    echo "[GEOCODE] This is not ROI/GRD cropping; gc_map is limited by DEM coverage." >&2
    echo "[GEOCODE] Use a wider DEM via: DEM=/path/EQA.dem DEM_PAR=/path/EQA.dem_par" >&2
    echo "[GEOCODE] QC report: $report" >&2
    if [[ "${GEOCODE_FAIL_ON_DEM_EDGE_CLIP}" -eq 1 ]]; then
      echo "[ERROR] Geocoded output is clipped by insufficient DEM coverage." >&2
      return 42
    fi
  elif [[ $st -ne 0 ]]; then
    echo "[GEOCODE] extent QC returned status $st; see $report" >&2
  fi
  return 0
}

write_grd_outputs(){
  if [[ "$DO_WRITE_GRD" -ne 1 ]]; then
    log "DO_WRITE_GRD=0; skip GRD outputs"
    return 0
  fi

  log "Write GMT/GRD outputs -> $GRD_DIR"
  mkdir -p "$GRD_DIR"
  if [[ "$FORCE_GRD" -eq 1 ]]; then
    rm -f "$GRD_DIR"/*.grd "$GRD_DIR"/*.tif "$GRD_DIR"/*.aux.xml "$GRD_DIR"/GRD_SUMMARY.txt 2>/dev/null || true
  fi

  # Prepare optional look-vector angle grids in the same map grid as the geocoded phase.
  # Preferred: GAMMA look_vector -> lv_theta/lv_phi. Fallback: gc_map inc/psi outputs.
  local theta_file="${ADF_GEO_DIR}/lv_theta"
  local phi_file="${ADF_GEO_DIR}/lv_phi"
  if [[ ! -s "$theta_file" || ! -s "$phi_file" ]]; then
    if command -v look_vector >/dev/null 2>&1; then
      (
        cd "$ADF_GEO_DIR"
        look_vector "$REF_MOSAIC_PAR" - EQA.rdc.dem_par EQA.rdc.dem lv_theta lv_phi
      ) > "${ADF_LOG_DIR}/look_vector.log" 2>&1 || true
    fi
  fi

  python3 - <<PY
import os, re, math, sys
import numpy as np

try:
    from osgeo import gdal, osr
except Exception as e:
    raise SystemExit(f"[GRD] Python GDAL/osgeo is required to write GRD/TIF outputs: {e}")

pair='${PAIR}'
look='${LOOK}'
adf_tag='${ADF_TAG}'
geo_dir='${ADF_GEO_DIR}'
look_geo_dir='${LOOK_GEO_DIR}'
grddir='${GRD_DIR}'
os.makedirs(grddir, exist_ok=True)

phase_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_PHASE}'))
cc_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_CC}'))
los_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_LOS_M}'))
par_file=os.path.join(geo_dir, 'EQA.rdc.dem_par')
dem_file=os.path.join(geo_dir, 'EQA.rdc.dem')

theta_file=os.path.join(geo_dir, 'lv_theta')
phi_file=os.path.join(geo_dir, 'lv_phi')
inc_file=os.path.join(look_geo_dir, 'inc')
psi_file=os.path.join(look_geo_dir, 'psi')

def read_par(fn):
    out={}
    pat=re.compile(r'^\s*(\S+):\s+([+-]?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)')
    with open(fn, 'r', errors='ignore') as f:
        for line in f:
            m=pat.match(line)
            if m:
                k,v=m.group(1),m.group(2)
                out[k]=int(float(v)) if k in ['width','nlines'] else float(v)
    return out

def read_be_f4(fn, shape, required=True):
    if not os.path.exists(fn) or os.path.getsize(fn) == 0:
        if required:
            raise FileNotFoundError(fn)
        return None
    arr=np.fromfile(fn, dtype='>f4')
    if arr.size != shape[0]*shape[1]:
        raise RuntimeError(f"Unexpected size for {fn}: {arr.size}, expected {shape[0]*shape[1]}")
    return arr.reshape(shape)

def maybe_angle_to_rad(a):
    finite=a[np.isfinite(a)]
    if finite.size == 0:
        return a
    if np.nanmax(np.abs(finite)) > 2*np.pi + 0.1:
        return np.deg2rad(a)
    return a

def crop_slices(lons, lats):
    if int('${GRD_CROP_TO_ROI}') != 1:
        return slice(0, len(lats)), slice(0, len(lons))
    roi_lon_min=float('${ROI_LON_MIN}'); roi_lon_max=float('${ROI_LON_MAX}')
    roi_lat_min=float('${ROI_LAT_MIN}'); roi_lat_max=float('${ROI_LAT_MAX}')
    x=np.where((lons >= roi_lon_min) & (lons <= roi_lon_max))[0]
    y=np.where((lats >= roi_lat_min) & (lats <= roi_lat_max))[0]
    if x.size == 0 or y.size == 0:
        print('[GRD] Warning: requested ROI does not overlap grid. Writing full geocoded grid.')
        return slice(0, len(lats)), slice(0, len(lons))
    return slice(y[0], y[-1]+1), slice(x[0], x[-1]+1)

def write_grid(out_name, data, lons_cut, lats_cut, post_lon, post_lat):
    data=np.asarray(data, dtype=np.float32)
    rows, cols=data.shape
    gt=(float(lons_cut[0]), float(post_lon), 0.0, float(lats_cut[0]), 0.0, float(post_lat))
    mem_driver=gdal.GetDriverByName('MEM')
    mem_ds=mem_driver.Create('', cols, rows, 1, gdal.GDT_Float32)
    mem_ds.SetGeoTransform(gt)
    srs=osr.SpatialReference(); srs.ImportFromEPSG(4326)
    mem_ds.SetProjection(srs.ExportToWkt())
    band=mem_ds.GetRasterBand(1)
    band.WriteArray(data)
    try:
        band.SetNoDataValue(np.nan)
    except Exception:
        pass
    driver_name='${GRD_DRIVER}'
    driver=gdal.GetDriverByName(driver_name)
    final_name=out_name
    if driver is None:
        print(f"[GRD] Warning: GDAL driver {driver_name!r} not found; falling back to GTiff")
        driver_name='GTiff'
        driver=gdal.GetDriverByName(driver_name)
        final_name=out_name[:-4] + '.tif' if out_name.endswith('.grd') else out_name + '.tif'
    if driver is None:
        raise RuntimeError('Neither GMT nor GTiff GDAL drivers are available')
    out_path=os.path.join(grddir, final_name)
    if os.path.exists(out_path):
        os.remove(out_path)
    dst=driver.CreateCopy(out_path, mem_ds, 0)
    dst=None; mem_ds=None
    aux=out_path+'.aux.xml'
    if os.path.exists(aux):
        try: os.remove(aux)
        except OSError: pass
    print(f"[GRD] Saved {final_name}")
    return out_path

par=read_par(par_file)
w,n=par['width'], par['nlines']
shape=(n,w)
corner_lat,corner_lon=par['corner_lat'], par['corner_lon']
post_lat,post_lon=par['post_lat'], par['post_lon']
lons=corner_lon + np.arange(w)*post_lon
lats=corner_lat + np.arange(n)*post_lat
ys,xs=crop_slices(lons,lats)
lons_cut=lons[xs]
lats_cut=lats[ys]

wrap_phase=read_be_f4(phase_file, shape, required=True)
coh=read_be_f4(cc_file, shape, required=True)
dem=read_be_f4(dem_file, shape, required=False)
los=read_be_f4(los_file, shape, required=False)

mask=np.zeros(shape, dtype=bool)
if int('${GRD_APPLY_COH_MASK}') == 1:
    mask |= ~(np.isfinite(coh) & (coh >= float('${GRD_COH_THRESHOLD}')))
if int('${GRD_APPLY_WATER_MASK}') == 1 and dem is not None:
    mask |= (~np.isfinite(dem)) | (dem <= float('${GRD_WATER_DEM_THRESHOLD}'))

wrap_save=wrap_phase.copy(); wrap_save[mask | ~np.isfinite(wrap_save)] = np.nan
coh_save=coh.copy(); coh_save[~np.isfinite(coh_save)] = np.nan

# Build final LOS product. v9.2 applies an additional map-grid reference correction
# here, after geocoding and using the exact mask/output grid. This avoids the common
# problem where all plotted LOS values are positive/negative due to an arbitrary
# unwrapping constant or a stale radar-coordinate reference.
los_ref_value=0.0
los_ref_pixels=0
los_ref_mode='${GRD_LOS_REF_MODE}'.lower()
los_raw_save=None
if los is None:
    if int('${GRD_WRITE_NAN_LOS_IF_NO_UNW}') == 1:
        los_save=np.full(shape, np.nan, dtype=np.float32)
        print('[GRD] Warning: LOS/unwrapped product not found; writing all-NaN los_disp grid.')
    else:
        los_save=None
        print('[GRD] Warning: LOS/unwrapped product not found; skip los_disp.grd. Set DO_UNWRAP=1 or GRD_WRITE_NAN_LOS_IF_NO_UNW=1.')
else:
    los_raw_save=los.copy()
    finite_los=np.isfinite(los_raw_save)
    # Reference mask uses coherence and optional water/DEM screening even if the
    # output itself keeps low-coherence pixels.
    ref_mask=finite_los & np.isfinite(coh) & (coh >= float('${GRD_LOS_REF_COH_THRESHOLD}'))
    if int('${GRD_LOS_REF_WATER_MASK}') == 1 and dem is not None:
        ref_mask &= np.isfinite(dem) & (dem > float('${GRD_LOS_REF_WATER_THRESHOLD}'))
    out_area=np.zeros(shape, dtype=bool)
    out_area[ys, xs]=True
    if los_ref_mode == 'none':
        ref_mask[:] = False
    elif los_ref_mode == 'output_median':
        ref_mask &= out_area
    elif los_ref_mode == 'global':
        pass
    elif los_ref_mode == 'box':
        lon2, lat2 = np.meshgrid(lons, lats)
        ref_mask &= (lon2 >= float('${GRD_LOS_REF_LON_MIN}')) & (lon2 <= float('${GRD_LOS_REF_LON_MAX}')) &                     (lat2 >= float('${GRD_LOS_REF_LAT_MIN}')) & (lat2 <= float('${GRD_LOS_REF_LAT_MAX}'))
    else:
        print(f'[GRD] Warning: unknown GRD_LOS_REF_MODE={los_ref_mode!r}; using no LOS reference correction')
        ref_mask[:] = False
    los_ref_pixels=int(np.count_nonzero(ref_mask))
    if los_ref_pixels >= 50:
        los_ref_value=float(np.nanmedian(los_raw_save[ref_mask]))
    else:
        if los_ref_mode != 'none':
            print(f'[GRD] Warning: too few LOS reference pixels ({los_ref_pixels}); no map-grid LOS reference correction applied')
        los_ref_value=0.0
    los_save=los_raw_save - los_ref_value
    los_raw_save[mask | ~np.isfinite(los_raw_save)] = np.nan
    los_save[mask | ~np.isfinite(los_save)] = np.nan

theta=read_be_f4(theta_file, shape, required=False)
phi=read_be_f4(phi_file, shape, required=False)
vector_source='look_vector lv_theta/lv_phi'
if theta is None or phi is None:
    theta=read_be_f4(inc_file, shape, required=False)
    phi=read_be_f4(psi_file, shape, required=False)
    vector_source='gc_map inc/psi fallback'

if theta is None or phi is None:
    print('[GRD] Warning: no look-vector angle grids found; writing NaN vec_E/N/U grids.')
    vec_E=vec_N=vec_U=np.full(shape, np.nan, dtype=np.float32)
else:
    th=maybe_angle_to_rad(theta)
    ph=maybe_angle_to_rad(phi)
    vec_E=(-np.sin(ph)*np.sin(th)).astype(np.float32)
    vec_N=(-np.cos(ph)*np.sin(th)).astype(np.float32)
    vec_U=( np.cos(th)).astype(np.float32)
    bad=mask | ~np.isfinite(vec_E) | ~np.isfinite(vec_N) | ~np.isfinite(vec_U)
    vec_E[bad]=np.nan; vec_N[bad]=np.nan; vec_U[bad]=np.nan

def C(a): return a[ys, xs]

written=[]
if los_raw_save is not None and int('${GRD_WRITE_RAW_LOS}') == 1:
    written.append(write_grid('los_disp_raw.grd', C(los_raw_save), lons_cut, lats_cut, post_lon, post_lat))
if los_save is not None:
    written.append(write_grid('los_disp.grd', C(los_save), lons_cut, lats_cut, post_lon, post_lat))
written.append(write_grid('coherence.grd', C(coh_save), lons_cut, lats_cut, post_lon, post_lat))
written.append(write_grid('wrap_phase.grd', C(wrap_save), lons_cut, lats_cut, post_lon, post_lat))
written.append(write_grid('vec_E.grd', C(vec_E), lons_cut, lats_cut, post_lon, post_lat))
written.append(write_grid('vec_N.grd', C(vec_N), lons_cut, lats_cut, post_lon, post_lat))
written.append(write_grid('vec_U.grd', C(vec_U), lons_cut, lats_cut, post_lon, post_lat))

with open(os.path.join(grddir, 'GRD_SUMMARY.txt'), 'w') as f:
    f.write(f'pair: {pair}\nlook: {look}\nadf_tag: {adf_tag}\n')
    f.write(f'source_phase: {phase_file}\nsource_coherence: {cc_file}\nsource_los: {los_file}\n')
    f.write(f'grd_crop_to_roi: ${GRD_CROP_TO_ROI}\n')
    f.write(f'roi_lon: ${ROI_LON_MIN} ${ROI_LON_MAX}\nroi_lat: ${ROI_LAT_MIN} ${ROI_LAT_MAX}\n')
    f.write(f'grid_shape_written: {C(coh_save).shape}\n')
    f.write(f'grid_lon_extent: {lons_cut[0]} {lons_cut[-1]}\n')
    f.write(f'grid_lat_extent: {lats_cut[-1]} {lats_cut[0]}\n')
    f.write(f'mosaic_source_mode: ${MOSAIC_SOURCE_MODE_USED:-unknown}\n')
    f.write(f'corner_lon: {lons_cut[0]}\ncorner_lat: {lats_cut[0]}\npost_lon: {post_lon}\npost_lat: {post_lat}\n')
    f.write(f'apply_coh_mask: ${GRD_APPLY_COH_MASK}\ngrd_coh_threshold: ${GRD_COH_THRESHOLD}\n')
    f.write(f'apply_water_mask: ${GRD_APPLY_WATER_MASK}\nwater_dem_threshold: ${GRD_WATER_DEM_THRESHOLD}\n')
    f.write(f'unw_ref_mode: ${UNW_REF_MODE}\nunw_ref_coh_threshold: ${UNW_REF_COH_THRESHOLD}\n')
    f.write(f'unw_output_apply_mask: ${UNW_OUTPUT_APPLY_MASK}\nunw_output_coh_threshold: ${UNW_OUTPUT_COH_THRESHOLD}\n')
    f.write(f'grd_los_ref_mode: ${GRD_LOS_REF_MODE}\n')
    f.write(f'grd_los_ref_coh_threshold: ${GRD_LOS_REF_COH_THRESHOLD}\n')
    f.write(f'grd_los_ref_value_m_subtracted: {los_ref_value}\n')
    f.write(f'grd_los_ref_pixels: {los_ref_pixels}\n')
    f.write(f'grd_los_ref_box: ${GRD_LOS_REF_LON_MIN} ${GRD_LOS_REF_LON_MAX} ${GRD_LOS_REF_LAT_MIN} ${GRD_LOS_REF_LAT_MAX}\n')
    f.write(f'snaphu_qc: ${SNAPHU_QC}\n')
    f.write(f'vector_source: {vector_source}\n')
    f.write('outputs:\n')
    for x in written:
        f.write(f'  {x}\n')
print(f'[GRD] Summary: {os.path.join(grddir, "GRD_SUMMARY.txt")}')
PY
}

plot_roi(){
  log "Plot outputs (crop_to_roi=${PLOT_CROP_TO_ROI}) -> $PLOT_DIR"
  mkdir -p "$PLOT_DIR"
  if [[ "$FORCE_PLOT" -eq 1 ]]; then
    rm -f "${PLOT_DIR}"/*.png "${PLOT_DIR}"/*.txt 2>/dev/null || true
  fi
  python3 - <<PY
import os, re, math
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap

pair='${PAIR}'
look='${LOOK}'
adf_tag='${ADF_TAG}'
geo_dir='${ADF_GEO_DIR}'
plot_dir='${PLOT_DIR}'
phase0_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_PHASE}'))
phase_adf_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_PHASE}'))
cc_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_CC}'))
unw_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_UNW}'))
los_file=os.path.join(geo_dir, 'EQA.' + os.path.basename('${DIFF0_ADF_LOS_M}'))
par_file=os.path.join(geo_dir, 'EQA.rdc.dem_par')
dem_file=os.path.join(geo_dir, 'EQA.rdc.dem')

roi_lon_min=float('${ROI_LON_MIN}'); roi_lon_max=float('${ROI_LON_MAX}')
roi_lat_min=float('${ROI_LAT_MIN}'); roi_lat_max=float('${ROI_LAT_MAX}')
marker_on=int('${MARKER_ON}'); marker_lon=float('${MARKER_LON}'); marker_lat=float('${MARKER_LAT}')
plot_crop_to_roi=int('${PLOT_CROP_TO_ROI}')
plot_scope='roi' if plot_crop_to_roi == 1 else 'full'
plot_coh_threshold=float('${PLOT_COH_THRESHOLD}')
mask_water=int('${MASK_WATER}'); water_dem_threshold=float('${WATER_DEM_THRESHOLD}')
remove_ramp=int('${REMOVE_RAMP}'); ramp_fit_coh_threshold=float('${RAMP_FIT_COH_THRESHOLD}')

os.makedirs(plot_dir, exist_ok=True)

def read_par(fn):
    out={}
    pat=re.compile(r'^\s*(\S+):\s+([+-]?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)')
    with open(fn, 'r', errors='ignore') as f:
        for line in f:
            m=pat.match(line)
            if m:
                k,v=m.group(1),m.group(2)
                out[k]=int(float(v)) if k in ['width','nlines'] else float(v)
    return out

def cmap_with_bad(name='hsv', bad='#d7d2f0'):
    base=plt.cm.get_cmap(name, 256)
    cmap=ListedColormap(base(np.linspace(0,1,256)))
    cmap.set_bad(color=bad)
    return cmap

def wrap(x):
    return (x + np.pi) % (2*np.pi) - np.pi

par=read_par(par_file)
w,n=par['width'], par['nlines']
corner_lat,corner_lon=par['corner_lat'], par['corner_lon']
post_lat,post_lon=par['post_lat'], par['post_lon']
lons=corner_lon + np.arange(w)*post_lon
lats=corner_lat + np.arange(n)*post_lat

phase0=np.fromfile(phase0_file, dtype='>f4').reshape(n,w)
phase_adf=np.fromfile(phase_adf_file, dtype='>f4').reshape(n,w)
cc=np.fromfile(cc_file, dtype='>f4').reshape(n,w)
if os.path.exists(dem_file) and mask_water:
    dem=np.fromfile(dem_file, dtype='>f4').reshape(n,w)
    water_mask=(~np.isfinite(dem)) | (dem <= water_dem_threshold)
else:
    dem=None
    water_mask=np.zeros((n,w), dtype=bool)

if plot_crop_to_roi == 1:
    col0=int(np.floor((roi_lon_min-corner_lon)/post_lon))
    col1=int(np.ceil((roi_lon_max-corner_lon)/post_lon))+1
    if post_lat < 0:
        row0=int(np.floor((roi_lat_max-corner_lat)/post_lat))
        row1=int(np.ceil((roi_lat_min-corner_lat)/post_lat))+1
    else:
        row0=int(np.floor((roi_lat_min-corner_lat)/post_lat))
        row1=int(np.ceil((roi_lat_max-corner_lat)/post_lat))+1
    row0,row1=max(0,row0),min(n,row1)
    col0,col1=max(0,col0),min(w,col1)
    if row1 <= row0 or col1 <= col0:
        raise RuntimeError(f'Invalid ROI crop: rows {row0}:{row1}, cols {col0}:{col1}')
else:
    row0,row1,col0,col1=0,n,0,w

extent=[lons[col0], lons[col1-1], lats[row1-1], lats[row0]]
phase0_roi=phase0[row0:row1, col0:col1]
phase_adf_roi=phase_adf[row0:row1, col0:col1]
cc_roi=cc[row0:row1, col0:col1]
mask=water_mask[row0:row1, col0:col1].copy()
if plot_coh_threshold > 0:
    mask |= (cc_roi < plot_coh_threshold)

if remove_ramp:
    yy,xx=np.indices(phase_adf_roi.shape)
    unw_tmp=np.unwrap(np.unwrap(phase_adf_roi,axis=1),axis=0)
    fit_mask=np.isfinite(unw_tmp) & np.isfinite(cc_roi) & (cc_roi >= ramp_fit_coh_threshold) & (~mask)
    if fit_mask.sum() > 100:
        A=np.column_stack([xx[fit_mask], yy[fit_mask], np.ones(fit_mask.sum())])
        b=unw_tmp[fit_mask]
        coef,*_=np.linalg.lstsq(A,b,rcond=None)
        phase_adf_roi=wrap(unw_tmp - (coef[0]*xx+coef[1]*yy+coef[2]))

cmap=cmap_with_bad('hsv','#d7d2f0')

def add_marker():
    if marker_on:
        plt.plot(marker_lon, marker_lat, marker='*', markersize=16, markerfacecolor='white', markeredgecolor='black', markeredgewidth=1.0, zorder=10)

def save_wrapped(data, mask, title, out):
    plt.figure(figsize=(8,7))
    plt.imshow(np.ma.masked_where(mask, data), extent=extent, origin='upper', vmin=-np.pi, vmax=np.pi, cmap=cmap, interpolation='none')
    add_marker(); plt.xlabel('Longitude'); plt.ylabel('Latitude'); plt.title(title); plt.colorbar(label='Phase (rad)'); plt.tight_layout(); plt.savefig(out, dpi=220); plt.close()

save_wrapped(phase0_roi, mask, f'{pair} {look} unfiltered differential wrapped phase', os.path.join(plot_dir, f'EQA.{pair}_{look}.diff0.phase.{plot_scope}.png'))
save_wrapped(phase_adf_roi, mask, f'{pair} {look} {adf_tag} ADF wrapped phase', os.path.join(plot_dir, f'EQA.{pair}_{look}.{adf_tag}.phase.{plot_scope}.png'))

plt.figure(figsize=(8,7))
plt.imshow(np.ma.masked_where(water_mask[row0:row1,col0:col1], cc_roi), extent=extent, origin='upper', vmin=0, vmax=1, cmap='viridis', interpolation='none')
add_marker(); plt.xlabel('Longitude'); plt.ylabel('Latitude'); plt.title(f'{pair} {look} {adf_tag} coherence'); plt.colorbar(label='Coherence'); plt.tight_layout(); plt.savefig(os.path.join(plot_dir, f'EQA.{pair}_{look}.{adf_tag}.cc.{plot_scope}.png'), dpi=220); plt.close()

if os.path.exists(unw_file):
    try:
        unw=np.fromfile(unw_file, dtype='>f4').reshape(n,w)[row0:row1, col0:col1]
        unw_mask=mask | (~np.isfinite(unw))
        vals=unw[~unw_mask]
        if vals.size > 0:
            vmin,vmax=np.nanpercentile(vals,[2,98])
        else:
            vmin,vmax=np.nanmin(unw),np.nanmax(unw)
        plt.figure(figsize=(8,7))
        plt.imshow(np.ma.masked_where(unw_mask, unw), extent=extent, origin='upper', vmin=vmin, vmax=vmax, cmap='RdYlBu_r', interpolation='none')
        add_marker(); plt.xlabel('Longitude'); plt.ylabel('Latitude'); plt.title(f'{pair} {look} {adf_tag} ${UNW_ENGINE} unwrapped phase'); plt.colorbar(label='Unwrapped phase (rad)'); plt.tight_layout(); plt.savefig(os.path.join(plot_dir, f'EQA.{pair}_{look}.{adf_tag}.${UNW_ENGINE}.unw.{plot_scope}.png'), dpi=220); plt.close()
    except Exception as e:
        print('[WARN] Unwrapped plot failed:', e)

if os.path.exists(los_file):
    try:
        los=np.fromfile(los_file, dtype='>f4').reshape(n,w)[row0:row1, col0:col1] * 100.0  # cm
        los_mask=mask | (~np.isfinite(los))
        vals=los[~los_mask]
        if vals.size > 0:
            q=np.nanpercentile(vals,[2,98])
            vmax=max(abs(q[0]),abs(q[1]))
            if not np.isfinite(vmax) or vmax == 0: vmax=1.0
        else:
            vmax=1.0
        plt.figure(figsize=(8,7))
        plt.imshow(np.ma.masked_where(los_mask, los), extent=extent, origin='upper', vmin=-vmax, vmax=vmax, cmap='RdYlBu_r', interpolation='none')
        add_marker(); plt.xlabel('Longitude'); plt.ylabel('Latitude'); plt.title(f'{pair} {look} {adf_tag} LOS displacement'); plt.colorbar(label='LOS displacement (cm)'); plt.tight_layout(); plt.savefig(os.path.join(plot_dir, f'EQA.{pair}_{look}.{adf_tag}.${UNW_ENGINE}.los_cm.{plot_scope}.png'), dpi=220); plt.close()
    except Exception as e:
        print('[WARN] LOS plot failed:', e)

valid=np.isfinite(cc_roi) & (cc_roi>=0) & (cc_roi<=1)
with open(os.path.join(plot_dir, f'{pair}_{look}.{adf_tag}.{plot_scope}_stats.txt'),'w') as f:
    f.write(f'pair: {pair}\nlook: {look}\nadf_tag: {adf_tag}\n')
    f.write(f'adf_alpha: ${ADF_ALPHA}\nadf_nfft: ${ADF_NFFT}\nadf_ccwin: ${ADF_CCWIN}\n')
    f.write(f'plot_coh_threshold: {plot_coh_threshold}\nunw_coh_threshold: ${UNW_COH_THRESHOLD}\n')
    f.write(f'roi_lon: {roi_lon_min} {roi_lon_max}\nroi_lat: {roi_lat_min} {roi_lat_max}\n')
    f.write(f'coherence_mean: {np.nanmean(cc_roi[valid]):.4f}\ncoherence_median: {np.nanmedian(cc_roi[valid]):.4f}\n')
    f.write(f'coherence_p25_p75: {np.nanpercentile(cc_roi[valid],[25,75]).tolist()}\n')
print('PLOTS:', plot_dir)
PY
}

write_summary(){
  local split_strategy="whole_scene"
  [[ "$UNW_ENGINE" == "mk_unw_2d_branch_cut" ]] && split_strategy="manual_branch_cut_side_split"
  cat > "${ADF_DIR}/RUN_SUMMARY.txt" <<TXT
Script version: ${SCRIPT_VERSION}
Project root: ${PROJECT_ROOT}
Prepared inputs: ${PREPARED_INPUTS_FILE}
DEM source record: ${PROJECT_ROOT}/dem/DEM_SOURCE.txt
Pair: ${PAIR}
Science reference: ${REF}
Science secondary: ${SEC}
Polarization: ${POL}

Detected science satellites: REF=${REF_SAT}, SEC=${SEC_SAT}
Detected max bursts: REF=${REF_MAX_BURSTS}, SEC=${SEC_MAX_BURSTS}
Internal coreg reference: ${COREG_REF} (${COREG_REF_SAT})
Internal coreg secondary: ${COREG_SEC} (${COREG_SEC_SAT})
Internal coreg pair: ${COREG_PAIR}
Coreg order used: ${COREG_ORDER_USED}
Output phase sign applied to internal result: ${OUTPUT_PHASE_SIGN}
Coreg burst selection requested: ${COREG_BURST_SELECT}
Coreg burst selection used: ${COREG_BURST_SELECT_USED}
Coreg burst strategy requested: ${COREG_BURST_STRATEGY}
Coreg burst strategy used: ${COREG_BURST_STRATEGY_USED:-none}
Auto compatibility mode: ${AUTO_COMPAT_MODE}
Coreg secondary tab used: ${SEC_TAB_FOR_COREG}

Coreg cache: ${COREG_DIR}
Coreg looks: ${COREG_RLKS} x ${COREG_ALKS}
Coreg cc threshold: ${COREG_CC_THRESH}
Swaths: ${SWATHS_TO_PROCESS}
Pair is S1A-S1C: ${PAIR_IS_S1A_S1C}
SLC_intf common-band requested: SPS=${SPS_FLG}, AZF=${AZF_FLG}
SLC_intf common-band used: SPS=${SPS_FLG_USED}, AZF=${AZF_FLG_USED}
QC pass: ${QC_PASS:-unknown}
QC score: ${QC_SCORE:-unknown}
QC worst swath: ${QC_WORST_SWATH:-unknown}
QC report: ${QC_REPORT:-unknown}

Look cache: ${LOOK_DIR}
Final looks: ${RLKS} x ${ALKS}
ADF dir: ${ADF_DIR}
ADF: alpha=${ADF_ALPHA}, nfft=${ADF_NFFT}, ccwin=${ADF_CCWIN}
Plot dir: ${PLOT_DIR}
Plot coherence threshold: ${PLOT_COH_THRESHOLD}
Water mask: ${MASK_WATER}, DEM <= ${WATER_DEM_THRESHOLD} m

Unwrap engine: ${UNW_ENGINE}
Unwrap tag: ${UNW_TAG}
Split strategy: ${split_strategy}
Branch buffer km: ${BRANCH_BUFFER_KM}
Branch-cut file used: ${BRANCH_CUT_FILE}
North ref box: ${NORTH_REF_LON_MIN} ${NORTH_REF_LON_MAX} ${NORTH_REF_LAT_MIN} ${NORTH_REF_LAT_MAX}
South ref box: ${SOUTH_REF_LON_MIN} ${SOUTH_REF_LON_MAX} ${SOUTH_REF_LAT_MIN} ${SOUTH_REF_LAT_MAX}
DO_UNWRAP: ${DO_UNWRAP}
SNAPHU init: ${SNAPHU_INIT_METHOD}
SNAPHU cost: ${SNAPHU_COST_MODE}
UNW coherence threshold: ${UNW_COH_THRESHOLD}
UNW reference mode: ${UNW_REF_MODE}
UNW reference coherence threshold: ${UNW_REF_COH_THRESHOLD}
UNW remove plane: ${UNW_REMOVE_PLANE}
UNW output apply mask: ${UNW_OUTPUT_APPLY_MASK}
UNW output coherence threshold: ${UNW_OUTPUT_COH_THRESHOLD}
UNW output water mask: ${UNW_OUTPUT_WATER_MASK}, DEM > ${UNW_OUTPUT_WATER_THRESHOLD} m
SNAPHU QC: ${SNAPHU_QC}
Wavelength m: ${WAVELENGTH_M}
LOS sign: ${LOS_SIGN}

Main outputs:
  Wrapped ADF phase: ${DIFF0_ADF_PHASE}
  ADF coherence: ${DIFF0_ADF_CC}
  Raw unwrapped phase: ${DIFF0_ADF_UNW_RAW}
  Reference-corrected unwrapped phase: ${DIFF0_ADF_UNW}
  LOS displacement m, reference-corrected: ${DIFF0_ADF_LOS_M}
  Geocoded outputs: ${ADF_GEO_DIR}
  GRD outputs: ${GRD_DIR}
  DO_WRITE_GRD: ${DO_WRITE_GRD}
  GRD crop to ROI: ${GRD_CROP_TO_ROI}
  Plot crop to ROI: ${PLOT_CROP_TO_ROI}
  Mosaic source mode: ${MOSAIC_SOURCE_MODE_USED:-unknown}
  SLC_intf common azimuth lines: ${SLC_INTF_NLINES:--}
  SLC_intf max allowed azimuth mismatch: ${SLC_INTF_MAX_AZ_LINE_MISMATCH}
  GRD apply coherence mask: ${GRD_APPLY_COH_MASK}, threshold=${GRD_COH_THRESHOLD}
  GRD apply water mask: ${GRD_APPLY_WATER_MASK}, threshold=${GRD_WATER_DEM_THRESHOLD}
  Plots: ${PLOT_DIR}
TXT
}

write_result_manifest(){
  local mf="${RESULT_MANIFEST_PATH:-${ADF_DIR}/RESULT_MANIFEST.env}"
  mkdir -p "$(dirname "$mf")"
  {
    printf 'RESULT_QC_PASS=%q\n' "${QC_PASS:-0}"
    printf 'RESULT_QC_SCORE=%q\n' "${QC_SCORE:-0}"
    printf 'RESULT_QC_WORST_SWATH=%q\n' "${QC_WORST_SWATH:-unknown}"
    printf 'RESULT_QC_REPORT=%q\n' "${QC_REPORT:-}"
    printf 'RESULT_PLOT_DIR=%q\n' "$PLOT_DIR"
    printf 'RESULT_GRD_DIR=%q\n' "$GRD_DIR"
    printf 'RESULT_ADF_DIR=%q\n' "$ADF_DIR"
    printf 'RESULT_SUMMARY=%q\n' "${ADF_DIR}/RUN_SUMMARY.txt"
    printf 'RESULT_COREG_DIR=%q\n' "$COREG_DIR"
    printf 'RESULT_LOOK_DIR=%q\n' "$LOOK_DIR"
    printf 'RESULT_BSEL=%q\n' "$COREG_BURST_SELECT"
    printf 'RESULT_STRATEGY=%q\n' "$COREG_BURST_STRATEGY"
    printf 'RESULT_SPS=%q\n' "$SPS_FLG_USED"
    printf 'RESULT_AZF=%q\n' "$AZF_FLG_USED"
  } > "$mf"
}

manifest_value(){
  local mf="$1" key="$2"
  bash -c 'source "$1"; printf "%s" "${!2-}"' _ "$mf" "$key"
}

publish_selected_candidate(){
  local mf="$1" trial_log="$2"
  local final_dir="${WORKDIR}/FINAL_${PAIR}"
  local p g a sm qcr
  p=$(manifest_value "$mf" RESULT_PLOT_DIR)
  g=$(manifest_value "$mf" RESULT_GRD_DIR)
  a=$(manifest_value "$mf" RESULT_ADF_DIR)
  sm=$(manifest_value "$mf" RESULT_SUMMARY)
  qcr=$(manifest_value "$mf" RESULT_QC_REPORT)
  mkdir -p "$final_dir"
  ln -sfn "$p" "$final_dir/plots"
  ln -sfn "$g" "$final_dir/grd"
  ln -sfn "$a" "$final_dir/adf"
  ln -sfn "$sm" "$final_dir/RUN_SUMMARY.txt"
  [[ -n "$qcr" ]] && ln -sfn "$qcr" "$final_dir/AUTO_QC.txt"
  ln -sfn "$mf" "$final_dir/SELECTED_RESULT.env"
  ln -sfn "$trial_log" "$final_dir/selected_trial.log"
  cat > "$final_dir/FINAL_OUTPUTS.txt" <<TXT
Science pair: ${PAIR}
Selected manifest: ${mf}
Plots: ${p}
GRD: ${g}
ADF: ${a}
Summary: ${sm}
QC: ${qcr}
TXT
  log "Final selected outputs: $final_dir"
  log "Final plots: $final_dir/plots"
  log "Final GRD: $final_dir/grd"
}

publish_current_result(){
  [[ "$PUBLISH_FINAL" -eq 1 ]] || return 0
  local mf="${RESULT_MANIFEST_PATH:-${ADF_DIR}/RESULT_MANIFEST.env}"
  local final_dir="${WORKDIR}/FINAL_${PAIR}"
  mkdir -p "$final_dir"
  ln -sfn "$PLOT_DIR" "$final_dir/plots"
  ln -sfn "$GRD_DIR" "$final_dir/grd"
  ln -sfn "$ADF_DIR" "$final_dir/adf"
  ln -sfn "${ADF_DIR}/RUN_SUMMARY.txt" "$final_dir/RUN_SUMMARY.txt"
  ln -sfn "$mf" "$final_dir/SELECTED_RESULT.env"
  [[ -s "${QC_REPORT:-}" ]] && ln -sfn "$QC_REPORT" "$final_dir/AUTO_QC.txt"
  cat > "$final_dir/FINAL_OUTPUTS.txt" <<TXT
Science pair: ${PAIR}
Plots: ${PLOT_DIR}
GRD: ${GRD_DIR}
ADF: ${ADF_DIR}
Summary: ${ADF_DIR}/RUN_SUMMARY.txt
QC: ${QC_REPORT:-}
TXT
  log "Published final output links: $final_dir"
}

run_auto_compat_dispatch(){
  local script_self trial_root requested_unwrap
  script_self=$(readlink -f "${BASH_SOURCE[0]}")
  trial_root="${WORKDIR}/_auto_trials_${PAIR}"
  requested_unwrap="$DO_UNWRAP"
  mkdir -p "$trial_root"

  local candidates=()
  # Global last9 and first9 are complementary for this S1A-S1C pair: the logs
  # show IW1/IW2 prefer the trailing window while IW3 prefers the leading one.
  # Test the metadata-derived per-IW time_align window first.
  if [[ "$COREG_REF_MAX_BURSTS" -ne "$COREG_SEC_MAX_BURSTS" ]]; then
    candidates=("manual_count:time_align" "manual_count:last9" "none:auto" "manual_count:first9")
  else
    candidates=("none:auto")
  fi

  local cand bsel strat name manifest logf status selected_manifest="" selected_log=""
  for cand in "${candidates[@]}"; do
    IFS=: read -r bsel strat <<< "$cand"
    name="bsel${bsel}_strat${strat}_cb00"
    manifest="${trial_root}/${name}.env"
    logf="${trial_root}/${name}.log"
    log "Compatibility trial: ${name}"
    set +e
    env AUTO_TRIAL_CHILD=1 AUTO_COMPAT_MODE=0 QC_ENFORCE=1 QC_ENABLE=1 \
      RESULT_MANIFEST_PATH="$manifest" SWATHS_TO_PROCESS=all \
      COREG_BURST_SELECT="$bsel" COREG_BURST_STRATEGY="$strat" \
      SPS_FLG=0 AZF_FLG=0 DO_UNWRAP=0 \
      FORCE_COREG=1 FORCE_MOSAIC=1 FORCE_LOOK=1 FORCE_ADF=1 \
      FORCE_SNAPHU=0 FORCE_PLOT=1 FORCE_GRD=1 \
      bash "$script_self" > "$logf" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 && -s "$manifest" && "$(manifest_value "$manifest" RESULT_QC_PASS)" == "1" ]]; then
      selected_manifest="$manifest"; selected_log="$logf"
      log "Compatibility trial accepted: ${name}; QC score=$(manifest_value "$manifest" RESULT_QC_SCORE)"
      break
    fi
    log "Compatibility trial did not pass: ${name}; details kept in ${logf}"
  done

  if [[ -z "$selected_manifest" ]]; then
    echo "[ERROR] All S1A-S1C compatibility candidates failed or did not pass per-swath coherence QC." >&2
    echo "[ERROR] Inspect trial logs under: $trial_root" >&2
    return 1
  fi

  if [[ "$requested_unwrap" -eq 1 ]]; then
    local bsel strat final_manifest final_log
    bsel=$(manifest_value "$selected_manifest" RESULT_BSEL)
    strat=$(manifest_value "$selected_manifest" RESULT_STRATEGY)
    final_manifest="${trial_root}/selected_final.env"
    final_log="${trial_root}/selected_final.log"
    log "Re-run accepted candidate with requested unwrapping: bsel=${bsel}, strategy=${strat}"
    set +e
    env AUTO_TRIAL_CHILD=1 AUTO_COMPAT_MODE=0 QC_ENFORCE=1 QC_ENABLE=1 \
      RESULT_MANIFEST_PATH="$final_manifest" SWATHS_TO_PROCESS=all \
      COREG_BURST_SELECT="$bsel" COREG_BURST_STRATEGY="$strat" \
      SPS_FLG=0 AZF_FLG=0 DO_UNWRAP=1 UNW_ENGINE="$UNW_ENGINE" \
      FORCE_COREG=0 FORCE_MOSAIC=0 FORCE_LOOK=0 FORCE_ADF=0 \
      FORCE_SNAPHU=1 FORCE_PLOT=1 FORCE_GRD=1 \
      bash "$script_self" > "$final_log" 2>&1
    status=$?
    set -e
    if [[ $status -ne 0 || ! -s "$final_manifest" ]]; then
      echo "[ERROR] Accepted wrapped-phase candidate passed QC, but the final unwrap/export run failed." >&2
      echo "[ERROR] Inspect: $final_log" >&2
      return 1
    fi
    selected_manifest="$final_manifest"; selected_log="$final_log"
  fi

  publish_selected_candidate "$selected_manifest" "$selected_log"
}

main(){
  validate_release_configuration
  export_release_configuration
  check_inputs
  preflight_dependencies
  [[ "$PRINT_CONFIG" -eq 1 || "$CHECK_ONLY" -eq 1 ]] && print_resolved_configuration
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    log "Preflight check passed; no processing requested."
    return 0
  fi

  mkdir -p "$WORKDIR"
  detect_dem_change

  if [[ "$AUTO_COMPAT_MODE" -eq 1 && "$AUTO_TRIAL_CHILD" -eq 0 && "$PAIR_IS_S1A_S1C" -eq 1 && "${SWATHS_TO_PROCESS,,}" == "all" ]]; then
    run_auto_compat_dispatch
    return
  fi

  cd "$WORKDIR"
  prepare_coreg_cache
  make_interferogram
  run_quality_check
  prepare_geocode_and_height
  remove_topo
  run_adf
  unwrap_if_requested
  geocode_outputs
  check_geocode_edge_clipping
  write_grd_outputs
  plot_roi
  write_summary
  write_result_manifest
  [[ "$AUTO_TRIAL_CHILD" -eq 0 ]] && publish_current_result
  log "Done. Plots: ${PLOT_DIR}"
  [[ "$DO_WRITE_GRD" -eq 1 ]] && log "GRD outputs: ${GRD_DIR}"
  log "Summary: ${ADF_DIR}/RUN_SUMMARY.txt"
}

main "$@"
