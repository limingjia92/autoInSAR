#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# S1_gamma_prepare.sh
# Sentinel-1 TOPS input preparation for GAMMA pair processing
# Release-oriented companion for ISCE2/autoInSAR directory layouts
# ============================================================
#
# Purpose
# -------
# Prepare the common inputs needed by the later GAMMA InSAR/unwrapping
# script, e.g. S1_gamma_tops_ifg_adf_roi_v9_3_4_mk_unw_2d_branchcut.sh.
#
# This script is designed to work with data already downloaded by an
# ISCE2/autoInSAR workflow:
#   1) Sentinel-1 official L1 SLC ZIP files
#   2) Sentinel-1 orbit EOF files
#   3) optional ISCE-style DEM, or DEM tools prepare_dem.py/dem.py
#
# What it does
# ------------
#   A. Import the reference acquisition with S1_import_SLC_from_zipfiles.
#   B. Save the reference burst_number_table.
#   C. Import the secondary acquisition using the reference burst table.
#      This avoids burst-list mismatch between the two dates.
#   D. Write date-level absolute GAMMA SLC_tab files:
#        ${PROJECT_ROOT}/tabs/${REF}_${POL}.SLC_tab
#        ${PROJECT_ROOT}/tabs/${SEC}_${POL}.SLC_tab
#   E. Prepare a GAMMA DEM pair:
#        ${PROJECT_ROOT}/dem/EQA.dem
#        ${PROJECT_ROOT}/dem/EQA.dem_par
#
# Typical use
# -----------
#   1. Edit ISCE2_DIR, PROJECT_ROOT, REF and SEC in Section 0A.
#   2. Run:
#        chmod +x S1_gamma_prepare.sh
#        ./S1_gamma_prepare.sh
#   3. Check:
#        ${PROJECT_ROOT}/PREPARED_INPUTS.txt
#   4. Then run the pair-processing script.
#
# DEM modes
# ---------
#   DEM_MODE="make_with_dem_py"
#       Use ISCE-style DEM helpers prepare_dem.py and dem.py to download/stitch
#       a demLat*.dem file, then convert it to GAMMA EQA.dem/EQA.dem_par using
#       GAMMA srtm2dem. This is the most self-contained mode for a new region.
#
#   DEM_MODE="from_isce_dem"
#       Convert an existing ISCE/autoInSAR demLat*.dem file to GAMMA format.
#       Set ISCE_DEM_FILE explicitly, or set ISCE_DEM_ROOT and let the script
#       search for the newest demLat*.dem under that directory.
#
#   DEM_MODE="existing_gamma"
#       Reuse an existing GAMMA DEM pair. Set EXISTING_GAMMA_DEM and
#       EXISTING_GAMMA_DEM_PAR.
#
#   DEM_MODE="skip"
#       Do not prepare DEM. Use only if ${PROJECT_ROOT}/dem/EQA.dem and
#       EQA.dem_par are already valid.
#
# Notes
# -----
# - This script does not download Sentinel-1 SLCs or orbit files by itself.
#   It derives SLC/orbit/DEM input paths from one ISCE2_DIR and discovers
#   all Sentinel-1 ZIP slices matching REF and SEC automatically.
# - The final InSAR processing script expects PROJECT_ROOT/tabs and
#   PROJECT_ROOT/dem to exist.
# - v1.1 adds strict validation of imported SLC_tab targets and cleans
#   stale import outputs when FORCE_IMPORT=1, so failed imports are caught
#   in this prepare stage instead of later in S1_coreg_TOPS.
# - v1.2 adds SECONDARY_IMPORT_MODE.  The default auto mode first tries
#   reference-burst-table import, then falls back to independent secondary
#   import if the reference burst table is incompatible, which can happen
#   for cross-satellite pairs such as S1A-S1C.
# - v2 derives ISCE input paths from ISCE2_DIR, auto-discovers date-matched
#   ZIP slices, records an input manifest, and enforces DEM source provenance
#   so a DEM from another ISCE project cannot be silently reused.
# ============================================================

# ============================================================
# 0A. Pair-specific settings: normally edit only these values
# ============================================================

# ISCE2/autoInSAR project containing SLC/, orbits/, and DEM/.
ISCE2_DIR="${ISCE2_DIR:-/media/chen/g/limj/for_Kai/Venezuela_2026/ISCE_A33_0618_0625}"

# Separate output root for GAMMA products. Do not point this to ISCE2_DIR.
PROJECT_ROOT="${PROJECT_ROOT:-/media/chen/g/limj/for_Kai/Venezuela_2026/GAMMA_S1_A33_0618_0625}"

# Acquisition dates in YYYYMMDD format. ZIP discovery uses these dates.
REF="${REF:-20260618}"
SEC="${SEC:-20260625}"
POL="${POL:-vv}"

# Standard autoInSAR layout derived from ISCE2_DIR. These remain overridable.
ISCE_SLC_DIR="${ISCE_SLC_DIR:-${ISCE2_DIR}/SLC}"
ORBIT_DIR="${ORBIT_DIR:-${ISCE2_DIR}/orbits}"

# Leave these arrays empty for automatic discovery under ISCE_SLC_DIR.
# To override discovery, list full ZIP paths here.
REF_ZIPS=()
SEC_ZIPS=()

# Automatic ZIP discovery settings.
ZIP_SEARCH_MAXDEPTH="${ZIP_SEARCH_MAXDEPTH:-4}"
ZIP_NAME_PATTERN="${ZIP_NAME_PATTERN:-S1*_IW_SLC__*.zip}"

# ============================================================
# 0B. DEM settings: usually edit for a new geographic region
# ============================================================

# Choose one: make_with_dem_py, from_isce_dem, existing_gamma, skip
DEM_MODE="from_isce_dem"

# Integer-degree DEM bounds for make_with_dem_py.
# Use a region larger than the final ROI and larger than the radar footprint.
# Format: south/north/west/east in geographic degrees.
DEM_SOUTH=8
DEM_NORTH=13
DEM_WEST=-71
DEM_EAST=-67

# For DEM_MODE=from_isce_dem:
# Leave ISCE_DEM_FILE empty to search only inside ISCE2_DIR/DEM.
# A lowercase ISCE2_DIR/dem is accepted automatically when DEM/ is absent.
ISCE_DEM_FILE="${ISCE_DEM_FILE:-}"
ISCE_DEM_ROOT="${ISCE_DEM_ROOT:-}"
ALLOW_MULTIPLE_ISCE_DEMS="${ALLOW_MULTIPLE_ISCE_DEMS:-0}"

# For DEM_MODE=existing_gamma:
# Use these only if you already have a valid GAMMA DEM pair for this region.
EXISTING_GAMMA_DEM=""
EXISTING_GAMMA_DEM_PAR=""

# Recreate DEM even if PROJECT_ROOT/dem/EQA.dem already exists.
# Usually 0. Set 1 when changing DEM bounds/source.
FORCE_DEM="${FORCE_DEM:-0}"

# Safety defaults for a release workflow.
ALLOW_EXTERNAL_ISCE_INPUTS="${ALLOW_EXTERNAL_ISCE_INPUTS:-0}"
STRICT_DEM_PROVENANCE="${STRICT_DEM_PROVENANCE:-1}"

# ============================================================
# 0C. Run switches: usually leave unchanged
# ============================================================

RUN_IMPORT="${RUN_IMPORT:-1}"          # 1: import Sentinel-1 ZIPs and write SLC_tabs
RUN_DEM="${RUN_DEM:-1}"                # 1: prepare EQA.dem/EQA.dem_par
FORCE_IMPORT="${FORCE_IMPORT:-1}"      # 1: rerun import after changing input data
CHECK_ONLY="${CHECK_ONLY:-0}"              # 1: validate/discover inputs and write manifest, then exit

# Secondary import strategy:
#   auto                  : try reference_burst_table first; if it produces no valid SLCs, retry independent
#   reference_burst_table : force secondary import using reference burst table; best for same-satellite/same-burst-grid pairs
#   independent           : import secondary without reference burst table; useful for cross-satellite pairs (e.g., S1A-S1C)
SECONDARY_IMPORT_MODE="${SECONDARY_IMPORT_MODE:-auto}"

# ============================================================
# 0D. Advanced defaults: rarely changed
# ============================================================

# GAMMA custom wrapper. It must be in PATH.
S1_IMPORT_CMD="S1_import_SLC_from_zipfiles"

# S1_import_SLC_from_zipfiles arguments used here:
#   zip.list  burst_table_or_-  pol  flag1  flag2  orbit_dir  flag3
# These values worked for the local GAMMA setup used in this project.
S1_IMPORT_FLAG1=1
S1_IMPORT_FLAG2=0
S1_IMPORT_FLAG3=1

# DEM helper commands for DEM_MODE=make_with_dem_py.
PREPARE_DEM_CMD="prepare_dem.py"
DEM_PY_CMD="dem.py"
DEM_PY_EXTRA_FLAGS=("-s" "1" "-r" "-c" "-l" "-f" "--filling_value" "0")

# Working directories inside PROJECT_ROOT.
WORK_ROOT="${WORK_ROOT:-${PROJECT_ROOT}/import_burst_table}"
TAB_DIR="${TAB_DIR:-${PROJECT_ROOT}/tabs}"
DEM_DIR="${DEM_DIR:-${PROJECT_ROOT}/dem}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs_prepare}"
INPUT_MANIFEST="${PROJECT_ROOT}/INPUT_MANIFEST.txt"
DEM_PROVENANCE_FILE="${DEM_DIR}/DEM_SOURCE.txt"
SECONDARY_IMPORT_USED="unknown"

# ============================================================
# 1. Utility functions
# ============================================================

log(){ echo "[$(date '+%F %T')] $*"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: command not found: $1" >&2; exit 1; }; }
need_file(){ [[ -f "$1" ]] || { echo "ERROR: missing file: $1" >&2; exit 1; }; }
need_nonempty(){ [[ -s "$1" ]] || { echo "ERROR: missing or empty file: $1" >&2; exit 1; }; }


canonical_path(){
  python3 - "$1" <<'PY_PATH'
import os, sys
print(os.path.realpath(os.path.abspath(os.path.expanduser(sys.argv[1]))))
PY_PATH
}

path_is_within(){
  local child root
  child=$(canonical_path "$1")
  root=$(canonical_path "$2")
  [[ "$child" == "$root" || "$child" == "$root"/* ]]
}

require_under_isce_root(){
  local label="$1" path="$2"
  [[ "$ALLOW_EXTERNAL_ISCE_INPUTS" -eq 1 ]] && return 0
  if ! path_is_within "$path" "$ISCE2_DIR"; then
    echo "ERROR: ${label} is outside ISCE2_DIR:" >&2
    echo "       ${label}=${path}" >&2
    echo "       ISCE2_DIR=${ISCE2_DIR}" >&2
    echo "       Set ALLOW_EXTERNAL_ISCE_INPUTS=1 only when this is intentional." >&2
    exit 1
  fi
}

validate_date(){
  [[ "$1" =~ ^[0-9]{8}$ ]] || { echo "ERROR: invalid acquisition date: $1 (expected YYYYMMDD)" >&2; exit 1; }
}

discover_zips_for_date(){
  local date="$1" out_name="$2" found=()
  [[ -d "$ISCE_SLC_DIR" ]] || { echo "ERROR: ISCE SLC directory not found: $ISCE_SLC_DIR" >&2; exit 1; }
  mapfile -t found < <(
    find "$ISCE_SLC_DIR" -maxdepth "$ZIP_SEARCH_MAXDEPTH" -type f -name "$ZIP_NAME_PATTERN" -print 2>/dev/null \
      | awk -v d="$date" 'index($0, "_" d "T")>0' \
      | sort
  )
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "ERROR: no Sentinel-1 IW SLC ZIP found for date ${date}." >&2
    echo "       Search root: $ISCE_SLC_DIR" >&2
    echo "       Pattern: $ZIP_NAME_PATTERN containing _${date}T" >&2
    exit 1
  fi
  local -n target="$out_name"
  target=("${found[@]}")
}

validate_zip_array(){
  local label="$1" date="$2"; shift 2
  local z base
  [[ $# -gt 0 ]] || { echo "ERROR: ${label} ZIP list is empty." >&2; exit 1; }
  for z in "$@"; do
    need_nonempty "$z"
    require_under_isce_root "$label" "$z"
    base=$(basename "$z")
    [[ "$base" == S1?_IW_SLC__*.zip ]] || { echo "ERROR: unexpected Sentinel-1 ZIP name: $z" >&2; exit 1; }
    [[ "$base" == *"_${date}T"* ]] || { echo "ERROR: ${label} ZIP does not match date ${date}: $z" >&2; exit 1; }
  done
}

resolve_input_layout(){
  validate_date "$REF"
  validate_date "$SEC"
  [[ "$REF" != "$SEC" ]] || { echo "ERROR: REF and SEC are identical: $REF" >&2; exit 1; }
  [[ -d "$ISCE2_DIR" ]] || { echo "ERROR: ISCE2_DIR does not exist: $ISCE2_DIR" >&2; exit 1; }
  if [[ "$(canonical_path "$PROJECT_ROOT")" == "$(canonical_path "$ISCE2_DIR")" ]]; then
    echo "ERROR: PROJECT_ROOT must be separate from ISCE2_DIR." >&2
    exit 1
  fi

  # Resolve the conventional DEM directory only once from ISCE2_DIR.
  if [[ -z "$ISCE_DEM_ROOT" ]]; then
    if [[ -d "${ISCE2_DIR}/DEM" ]]; then
      ISCE_DEM_ROOT="${ISCE2_DIR}/DEM"
    elif [[ -d "${ISCE2_DIR}/dem" ]]; then
      ISCE_DEM_ROOT="${ISCE2_DIR}/dem"
    else
      ISCE_DEM_ROOT="${ISCE2_DIR}/DEM"
    fi
  fi

  require_under_isce_root "ISCE_SLC_DIR" "$ISCE_SLC_DIR"
  require_under_isce_root "ORBIT_DIR" "$ORBIT_DIR"
  require_under_isce_root "ISCE_DEM_ROOT" "$ISCE_DEM_ROOT"

  if [[ "$RUN_IMPORT" -eq 1 || "$CHECK_ONLY" -eq 1 ]]; then
    [[ ${#REF_ZIPS[@]} -gt 0 ]] || discover_zips_for_date "$REF" REF_ZIPS
    [[ ${#SEC_ZIPS[@]} -gt 0 ]] || discover_zips_for_date "$SEC" SEC_ZIPS
    validate_zip_array "REF_ZIPS" "$REF" "${REF_ZIPS[@]}"
    validate_zip_array "SEC_ZIPS" "$SEC" "${SEC_ZIPS[@]}"

    local rz sz
    for rz in "${REF_ZIPS[@]}"; do
      for sz in "${SEC_ZIPS[@]}"; do
        [[ "$(canonical_path "$rz")" != "$(canonical_path "$sz")" ]] || {
          echo "ERROR: the same ZIP is present in REF_ZIPS and SEC_ZIPS: $rz" >&2
          exit 1
        }
      done
    done
  fi
}

write_input_manifest(){
  mkdir -p "$PROJECT_ROOT"
  {
    echo "ISCE2_DIR=$(canonical_path "$ISCE2_DIR")"
    echo "PROJECT_ROOT=$(canonical_path "$PROJECT_ROOT")"
    echo "REF=$REF"
    echo "SEC=$SEC"
    echo "POL=$POL"
    echo "ISCE_SLC_DIR=$(canonical_path "$ISCE_SLC_DIR")"
    echo "ORBIT_DIR=$(canonical_path "$ORBIT_DIR")"
    echo "ISCE_DEM_ROOT=$(canonical_path "$ISCE_DEM_ROOT")"
    echo "REF_ZIPS_COUNT=${#REF_ZIPS[@]}"
    local z
    for z in "${REF_ZIPS[@]}"; do echo "REF_ZIP=$z"; done
    echo "SEC_ZIPS_COUNT=${#SEC_ZIPS[@]}"
    for z in "${SEC_ZIPS[@]}"; do echo "SEC_ZIP=$z"; done
  } > "$INPUT_MANIFEST"
  log "Input manifest: $INPUT_MANIFEST"
  log "Resolved ISCE2 inputs: SLC=$ISCE_SLC_DIR; orbits=$ORBIT_DIR; DEM root=$ISCE_DEM_ROOT"
  if [[ "$RUN_IMPORT" -eq 1 || "$CHECK_ONLY" -eq 1 ]]; then
    log "Discovered ZIP slices: REF=${#REF_ZIPS[@]}, SEC=${#SEC_ZIPS[@]}"
  fi
}

abs_path(){
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    echo "$(pwd)/$p"
  fi
}

abs_path_from(){
  local base_dir="$1" p="$2"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    echo "${base_dir}/${p}"
  fi
}

write_zip_list(){
  local date="$1"; shift
  local dir="${WORK_ROOT}/${date}"
  mkdir -p "$dir"
  : > "${dir}/zip.list"
  local z
  for z in "$@"; do
    need_file "$z"
    printf "%s\n" "$z" >> "${dir}/zip.list"
  done
  need_nonempty "${dir}/zip.list"
  log "Wrote ZIP list: ${dir}/zip.list"
}

find_tab(){
  local dir="$1" date="$2" pol="$3"
  local f
  for f in \
    "${dir}/${date}.${pol}.SLC_tab" \
    "${dir}/${date}_${pol}.SLC_tab" \
    "${dir}/${date}.${pol^^}.SLC_tab" \
    "${dir}/${date}_${pol^^}.SLC_tab" \
    "${dir}/${date}.SLC_tab" \
    "${dir}"/*.SLC_tab; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

absolutize_tab(){
  local src_tab="$1" dst_tab="$2"
  local base_dir
  base_dir=$(cd "$(dirname "$src_tab")" && pwd)
  : > "$dst_tab"
  while read -r slc par tops rest; do
    [[ -z "${slc:-}" ]] && continue
    [[ "${slc:0:1}" == "#" ]] && continue
    local aslc apar atops
    aslc=$(abs_path_from "$base_dir" "$slc")
    apar=$(abs_path_from "$base_dir" "$par")
    atops=$(abs_path_from "$base_dir" "$tops")
    printf "%s %s %s\n" "$aslc" "$apar" "$atops" >> "$dst_tab"
  done < "$src_tab"
  need_nonempty "$dst_tab"
}


validate_gamma_tab(){
  local label="$1" tab="$2" log_hint="$3" source_dir="${4:-}" fatal="${5:-1}"
  local ok=1 n=0 slc par tops rest prefix="ERROR"
  [[ "$fatal" -eq 0 ]] && prefix="TRIAL"
  if [[ ! -s "$tab" ]]; then
    echo "${prefix}: ${label} tab is missing or empty: $tab" >&2
    ok=0
  else
    while read -r slc par tops rest; do
      [[ -z "${slc:-}" ]] && continue
      [[ "${slc:0:1}" == "#" ]] && continue
      n=$((n+1))
      if [[ ! -s "$slc" || ! -s "$par" || ! -s "$tops" ]]; then
        echo "${prefix}: ${label} tab points to missing/empty GAMMA input:" >&2
        echo "  SLC=$slc" >&2
        echo "  PAR=$par" >&2
        echo "  TOPS=$tops" >&2
        ok=0
        continue
      fi
      for key in range_samples azimuth_lines radar_frequency prf azimuth_line_time; do
        if ! grep -q "^${key}:" "$par"; then
          echo "${prefix}: ${label} parameter file misses key '${key}': $par" >&2
          ok=0
        fi
      done
    done < "$tab"
  fi
  if [[ "$n" -eq 0 ]]; then
    echo "${prefix}: ${label} tab has no valid data rows: $tab" >&2
    ok=0
  fi
  if [[ "$ok" -ne 1 ]]; then
    echo "${prefix}: ${label} import output is incomplete." >&2
    echo "       Inspect import log: $log_hint" >&2
    if [[ -n "$source_dir" ]]; then
      echo "       Inspect source directory: $source_dir" >&2
    fi
    if [[ "$fatal" -eq 1 ]]; then
      exit 1
    else
      return 1
    fi
  fi
  log "Validated ${label} GAMMA tab: $tab (${n} row(s))"
  return 0
}

clean_import_outputs_if_requested(){
  [[ "$FORCE_IMPORT" -eq 1 ]] || return 0
  log "FORCE_IMPORT=1: clean previous import products for ${REF}/${SEC}"
  rm -rf "${WORK_ROOT}/${REF}" "${WORK_ROOT}/${SEC}"
  rm -f "${TAB_DIR}/${REF}_${POL}.SLC_tab" "${TAB_DIR}/${SEC}_${POL}.SLC_tab"
  rm -f "${PROJECT_ROOT}/ref.burst_number_table"
  rm -f "${LOG_DIR}/S1_import.${REF}.log" "${LOG_DIR}/S1_import.${SEC}.log"
}

# ============================================================
# 2. Sentinel-1 import with reference burst table
# ============================================================

import_reference(){
  local dir="${WORK_ROOT}/${REF}"
  local out_tab="${TAB_DIR}/${REF}_${POL}.SLC_tab"
  local ref_btab="${PROJECT_ROOT}/ref.burst_number_table"

  if [[ "$FORCE_IMPORT" -eq 0 && -s "$out_tab" && -s "$ref_btab" ]]; then
    log "Reuse reference import: $out_tab"
    return 0
  fi

  log "Import reference ${REF} without burst table"
  (
    cd "$dir"
    "$S1_IMPORT_CMD" zip.list - "$POL" "$S1_IMPORT_FLAG1" "$S1_IMPORT_FLAG2" "$ORBIT_DIR" "$S1_IMPORT_FLAG3"
  ) > "${LOG_DIR}/S1_import.${REF}.log" 2>&1

  local btab="${dir}/temp.burst_number_table_ref"
  if [[ ! -s "$btab" ]]; then
    btab=$(find "$dir" -maxdepth 2 -name '*burst*table*' -type f | head -1 || true)
  fi
  if [[ -z "${btab:-}" || ! -s "$btab" ]]; then
    echo "ERROR: reference burst_number_table was not created. Check ${LOG_DIR}/S1_import.${REF}.log" >&2
    exit 1
  fi
  cp -f "$btab" "$ref_btab"
  log "Wrote reference burst table: $ref_btab"

  local tab
  tab=$(find_tab "$dir" "$REF" "$POL") || { echo "ERROR: cannot find ${REF} SLC_tab in $dir" >&2; exit 1; }
  absolutize_tab "$tab" "$out_tab"
  validate_gamma_tab "reference" "$out_tab" "${LOG_DIR}/S1_import.${REF}.log" "$dir" 1
  log "Wrote reference tab: $out_tab"
}

reset_secondary_workdir(){
  local dir="${WORK_ROOT}/${SEC}"
  local tmp_zip="${WORK_ROOT}/.${SEC}.zip.list.$$"
  if [[ -s "${dir}/zip.list" ]]; then
    cp "${dir}/zip.list" "$tmp_zip"
  else
    echo "ERROR: cannot reset secondary workdir because zip.list is missing: ${dir}/zip.list" >&2
    exit 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$tmp_zip" "${dir}/zip.list"
  rm -f "$tmp_zip"
  rm -f "${TAB_DIR}/${SEC}_${POL}.SLC_tab"
}

run_secondary_import_attempt(){
  local attempt_name="$1" burst_arg="$2" log_file="$3"
  local dir="${WORK_ROOT}/${SEC}"
  local out_tab="${TAB_DIR}/${SEC}_${POL}.SLC_tab"

  log "Import secondary ${SEC} (${attempt_name})"
  (
    cd "$dir"
    "$S1_IMPORT_CMD" zip.list "$burst_arg" "$POL" "$S1_IMPORT_FLAG1" "$S1_IMPORT_FLAG2" "$ORBIT_DIR" "$S1_IMPORT_FLAG3"
  ) > "$log_file" 2>&1

  local tab
  if ! tab=$(find_tab "$dir" "$SEC" "$POL"); then
    echo "ERROR: cannot find ${SEC} SLC_tab in $dir" >&2
    echo "       Inspect import log: $log_file" >&2
    return 1
  fi
  absolutize_tab "$tab" "$out_tab"
  validate_gamma_tab "secondary" "$out_tab" "$log_file" "$dir" 0
}

import_secondary(){
  local dir="${WORK_ROOT}/${SEC}"
  local out_tab="${TAB_DIR}/${SEC}_${POL}.SLC_tab"
  local ref_btab="${PROJECT_ROOT}/ref.burst_number_table"
  need_file "$ref_btab"

  if [[ "$FORCE_IMPORT" -eq 0 && -s "$out_tab" ]]; then
    validate_gamma_tab "secondary" "$out_tab" "${LOG_DIR}/S1_import.${SEC}.log" "$dir" 1
    log "Reuse secondary import: $out_tab"
    return 0
  fi

  case "$SECONDARY_IMPORT_MODE" in
    reference_burst_table)
      run_secondary_import_attempt "reference_burst_table" "$ref_btab" "${LOG_DIR}/S1_import.${SEC}.reference_burst.log" || {
        echo "ERROR: secondary import failed with reference burst table." >&2
        echo "       For cross-satellite pairs, try SECONDARY_IMPORT_MODE=independent or auto." >&2
        exit 1
      }
      cp -f "${LOG_DIR}/S1_import.${SEC}.reference_burst.log" "${LOG_DIR}/S1_import.${SEC}.log"
      SECONDARY_IMPORT_USED="reference_burst_table"
      ;;

    independent)
      run_secondary_import_attempt "independent_no_reference_burst_table" "-" "${LOG_DIR}/S1_import.${SEC}.independent.log" || {
        echo "ERROR: secondary independent import failed." >&2
        exit 1
      }
      cp -f "${LOG_DIR}/S1_import.${SEC}.independent.log" "${LOG_DIR}/S1_import.${SEC}.log"
      SECONDARY_IMPORT_USED="independent"
      ;;

    auto)
      if run_secondary_import_attempt "reference_burst_table" "$ref_btab" "${LOG_DIR}/S1_import.${SEC}.reference_burst.log"; then
        log "Secondary reference-burst-table import succeeded."
        cp -f "${LOG_DIR}/S1_import.${SEC}.reference_burst.log" "${LOG_DIR}/S1_import.${SEC}.log"
        SECONDARY_IMPORT_USED="reference_burst_table"
      else
        log "Secondary reference-burst-table import failed or produced no valid SLC."
        log "Retry secondary import independently without reference burst table."
        reset_secondary_workdir
        run_secondary_import_attempt "independent_no_reference_burst_table" "-" "${LOG_DIR}/S1_import.${SEC}.independent.log" || {
          echo "ERROR: secondary independent import also failed." >&2
          echo "       Inspect logs:" >&2
          echo "         ${LOG_DIR}/S1_import.${SEC}.reference_burst.log" >&2
          echo "         ${LOG_DIR}/S1_import.${SEC}.independent.log" >&2
          exit 1
        }
        cp -f "${LOG_DIR}/S1_import.${SEC}.independent.log" "${LOG_DIR}/S1_import.${SEC}.log"
        SECONDARY_IMPORT_USED="independent"
      fi
      ;;

    *)
      echo "ERROR: unknown SECONDARY_IMPORT_MODE=$SECONDARY_IMPORT_MODE" >&2
      echo "       Use auto, reference_burst_table, or independent." >&2
      exit 1
      ;;
  esac

  log "Wrote secondary tab: $out_tab"
  log "Secondary import mode used: $SECONDARY_IMPORT_USED"
}

prepare_import(){
  need_cmd "$S1_IMPORT_CMD"
  need_file_orbit_dir
  mkdir -p "$WORK_ROOT" "$TAB_DIR" "$LOG_DIR"
  clean_import_outputs_if_requested

  write_zip_list "$REF" "${REF_ZIPS[@]}"
  write_zip_list "$SEC" "${SEC_ZIPS[@]}"

  import_reference
  import_secondary
}

need_file_orbit_dir(){
  if [[ ! -d "$ORBIT_DIR" ]]; then
    echo "WARNING: ORBIT_DIR does not exist: $ORBIT_DIR" >&2
    echo "         S1_import_SLC_from_zipfiles may still work if product orbit is used, but precise orbit update may be skipped." >&2
  fi
}

# ============================================================
# 3. DEM preparation
# ============================================================

find_isce_dem_file(){
  if [[ -n "${ISCE_DEM_FILE:-}" ]]; then
    [[ -f "$ISCE_DEM_FILE" ]] || { echo "ERROR: ISCE_DEM_FILE not found: $ISCE_DEM_FILE" >&2; exit 1; }
    require_under_isce_root "ISCE_DEM_FILE" "$ISCE_DEM_FILE"
    canonical_path "$ISCE_DEM_FILE"
    return 0
  fi

  [[ -d "$ISCE_DEM_ROOT" ]] || {
    echo "ERROR: ISCE DEM directory does not exist: $ISCE_DEM_ROOT" >&2
    echo "       Expected under ISCE2_DIR/DEM (or ISCE2_DIR/dem)." >&2
    exit 1
  }

  local found=()
  mapfile -t found < <(find "$ISCE_DEM_ROOT" -type f -name 'demLat*.dem' -print 2>/dev/null | sort)
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "ERROR: cannot find demLat*.dem under: $ISCE_DEM_ROOT" >&2
    echo "       Set ISCE_DEM_FILE explicitly or use DEM_MODE=make_with_dem_py." >&2
    exit 1
  fi
  if [[ ${#found[@]} -gt 1 && "$ALLOW_MULTIPLE_ISCE_DEMS" -ne 1 ]]; then
    echo "ERROR: multiple ISCE DEM files were found; refusing to choose one silently:" >&2
    printf '       %s\n' "${found[@]}" >&2
    echo "       Set ISCE_DEM_FILE explicitly, or ALLOW_MULTIPLE_ISCE_DEMS=1." >&2
    exit 1
  fi
  if [[ ${#found[@]} -gt 1 ]]; then
    # Explicit opt-in: choose the newest file by modification time.
    local newest
    newest=$(find "$ISCE_DEM_ROOT" -type f -name 'demLat*.dem' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    canonical_path "$newest"
  else
    canonical_path "${found[0]}"
  fi
}

prepare_gamma_dem(){
  mkdir -p "$DEM_DIR" "$LOG_DIR"
  local out_dem="${DEM_DIR}/EQA.dem"
  local out_par="${DEM_DIR}/EQA.dem_par"
  local resolved_isce_dem=""
  if [[ "$DEM_MODE" == "from_isce_dem" ]]; then
    resolved_isce_dem=$(find_isce_dem_file)
  fi

  if [[ "$FORCE_DEM" -eq 0 && -s "$out_dem" && -s "$out_par" ]]; then
    if [[ "$STRICT_DEM_PROVENANCE" -eq 1 ]]; then
      if [[ ! -s "$DEM_PROVENANCE_FILE" ]]; then
        echo "ERROR: existing GAMMA DEM has no provenance record: $DEM_PROVENANCE_FILE" >&2
        echo "       Set FORCE_DEM=1 once to rebuild it from the current ISCE2_DIR." >&2
        exit 1
      fi
      local recorded_mode recorded_source
      recorded_mode=$(awk -F= '$1=="DEM_MODE" {print substr($0,index($0,"=")+1)}' "$DEM_PROVENANCE_FILE")
      recorded_source=$(awk -F= '$1=="SOURCE_FILE" {print substr($0,index($0,"=")+1)}' "$DEM_PROVENANCE_FILE")
      if [[ "$recorded_mode" != "$DEM_MODE" ]]; then
        echo "ERROR: existing GAMMA DEM mode differs from current configuration." >&2
        echo "       recorded=$recorded_mode current=$DEM_MODE; set FORCE_DEM=1." >&2
        exit 1
      fi
      if [[ "$DEM_MODE" == "from_isce_dem" && "$(canonical_path "$recorded_source")" != "$(canonical_path "$resolved_isce_dem")" ]]; then
        echo "ERROR: existing GAMMA DEM came from a different ISCE DEM." >&2
        echo "       recorded=$recorded_source" >&2
        echo "       current=$resolved_isce_dem" >&2
        echo "       Set FORCE_DEM=1 to rebuild safely." >&2
        exit 1
      fi
    fi
    log "Reuse existing GAMMA DEM: $out_dem"
    return 0
  fi

  if [[ "$FORCE_DEM" -eq 1 ]]; then
    rm -f "$out_dem" "$out_par"
  fi

  case "$DEM_MODE" in
    skip)
      need_file "$out_dem"
      need_file "$out_par"
      log "DEM_MODE=skip; existing DEM checked."
      ;;

    existing_gamma)
      [[ -n "$EXISTING_GAMMA_DEM" && -n "$EXISTING_GAMMA_DEM_PAR" ]] || {
        echo "ERROR: DEM_MODE=existing_gamma requires EXISTING_GAMMA_DEM and EXISTING_GAMMA_DEM_PAR." >&2
        exit 1
      }
      need_file "$EXISTING_GAMMA_DEM"
      need_file "$EXISTING_GAMMA_DEM_PAR"
      ln -sf "$(readlink -f "$EXISTING_GAMMA_DEM")" "$out_dem"
      ln -sf "$(readlink -f "$EXISTING_GAMMA_DEM_PAR")" "$out_par"
      log "Linked existing GAMMA DEM -> $out_dem"
      ;;

    from_isce_dem)
      need_cmd srtm2dem
      log "Convert existing ISCE DEM to GAMMA DEM: $resolved_isce_dem -> $out_dem"
      srtm2dem "$resolved_isce_dem" "$out_dem" "$out_par" 1 - > "${LOG_DIR}/srtm2dem.from_isce_dem.log" 2>&1
      ;;

    make_with_dem_py)
      need_cmd srtm2dem
      need_cmd "$PREPARE_DEM_CMD"
      need_cmd "$DEM_PY_CMD"
      (
        cd "$DEM_DIR"
        local prep_north prep_east status dem_lat
        prep_north=$((DEM_NORTH - 1))
        prep_east=$((DEM_EAST - 1))

        log "Prepare DEM with final stitch bounds S/N/W/E = ${DEM_SOUTH}/${DEM_NORTH}/${DEM_WEST}/${DEM_EAST}"
        log "Download helper bounds for prepare_dem.py = ${DEM_SOUTH}/${prep_north}/${DEM_WEST}/${prep_east}"
        log "DEM stitch fills missing/ocean tiles with 0 m using: ${DEM_PY_EXTRA_FLAGS[*]}"
        {
          echo "COMMAND 1: $PREPARE_DEM_CMD $DEM_SOUTH $prep_north $DEM_WEST $prep_east"
          echo "COMMAND 2: $DEM_PY_CMD -a stitch -b $DEM_SOUTH $DEM_NORTH $DEM_WEST $DEM_EAST ${DEM_PY_EXTRA_FLAGS[*]}"
          echo
        } > "${LOG_DIR}/dem_prepare.log"

        set +e
        "$PREPARE_DEM_CMD" "$DEM_SOUTH" "$prep_north" "$DEM_WEST" "$prep_east" >> "${LOG_DIR}/dem_prepare.log" 2>&1
        status=$?
        set -e
        if [[ $status -ne 0 ]]; then
          echo "WARNING: prepare_dem.py returned non-zero status ($status). Continuing to dem.py; tiles may already exist locally." >&2
          echo "See log: ${LOG_DIR}/dem_prepare.log" >&2
        fi

        set +e
        "$DEM_PY_CMD" -a stitch -b "$DEM_SOUTH" "$DEM_NORTH" "$DEM_WEST" "$DEM_EAST" "${DEM_PY_EXTRA_FLAGS[@]}" >> "${LOG_DIR}/dem_prepare.log" 2>&1
        status=$?
        set -e
        if [[ $status -ne 0 ]]; then
          echo "ERROR: dem.py stitch failed. See log: ${LOG_DIR}/dem_prepare.log" >&2
          exit 1
        fi

        dem_lat=$(find . -maxdepth 1 -type f -name 'demLat*.dem' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)
        if [[ -z "$dem_lat" ]]; then
          echo "ERROR: demLat*.dem was not created in $DEM_DIR. See log: ${LOG_DIR}/dem_prepare.log" >&2
          exit 1
        fi

        log "Convert ISCE DEM to GAMMA DEM: $dem_lat -> EQA.dem/EQA.dem_par"
        srtm2dem "$dem_lat" EQA.dem EQA.dem_par 1 - > "${LOG_DIR}/srtm2dem.log" 2>&1
      )
      ;;

    *)
      echo "ERROR: unknown DEM_MODE=$DEM_MODE. Use make_with_dem_py, from_isce_dem, existing_gamma, or skip." >&2
      exit 1
      ;;
  esac

  need_nonempty "$out_dem"
  need_nonempty "$out_par"
  {
    echo "DEM_MODE=$DEM_MODE"
    echo "ISCE2_DIR=$(canonical_path "$ISCE2_DIR")"
    echo "ISCE_DEM_ROOT=$(canonical_path "$ISCE_DEM_ROOT")"
    echo "SOURCE_FILE=${resolved_isce_dem}"
    echo "OUTPUT_DEM=$(canonical_path "$out_dem")"
    echo "OUTPUT_PAR=$(canonical_path "$out_par")"
    echo "CREATED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$DEM_PROVENANCE_FILE"
  log "Prepared GAMMA DEM: $out_dem and $out_par"
  log "DEM provenance: $DEM_PROVENANCE_FILE"
}

# ============================================================
# 4. Summary and main
# ============================================================

write_summary(){
  local summary="${PROJECT_ROOT}/PREPARED_INPUTS.txt"
  cat > "$summary" <<TXT
ISCE2_DIR=${ISCE2_DIR}
PROJECT_ROOT=${PROJECT_ROOT}
REF=${REF}
SEC=${SEC}
POL=${POL}
ISCE_SLC_DIR=${ISCE_SLC_DIR}
ORBIT_DIR=${ORBIT_DIR}
REF_ZIPS_COUNT=${#REF_ZIPS[@]}
SEC_ZIPS_COUNT=${#SEC_ZIPS[@]}
INPUT_MANIFEST=${INPUT_MANIFEST}
REF_TAB=${TAB_DIR}/${REF}_${POL}.SLC_tab
SEC_TAB=${TAB_DIR}/${SEC}_${POL}.SLC_tab
REF_BURST_TABLE=${PROJECT_ROOT}/ref.burst_number_table
DEM=${DEM_DIR}/EQA.dem
DEM_PAR=${DEM_DIR}/EQA.dem_par
DEM_MODE=${DEM_MODE}
SECONDARY_IMPORT_MODE=${SECONDARY_IMPORT_MODE}
SECONDARY_IMPORT_USED=${SECONDARY_IMPORT_USED}
DEM_BOUNDS=${DEM_SOUTH}/${DEM_NORTH}/${DEM_WEST}/${DEM_EAST}
ISCE_DEM_FILE=${ISCE_DEM_FILE}
ISCE_DEM_ROOT=${ISCE_DEM_ROOT}
DEM_PROVENANCE_FILE=${DEM_PROVENANCE_FILE}
WORK_ROOT=${WORK_ROOT}
LOG_DIR=${LOG_DIR}
TXT
  log "Summary written: $summary"
}

usage(){
  cat <<'TXT'
Usage:
  ./S1_gamma_prepare.sh              Run import and DEM preparation according to settings in the script.
  ./S1_gamma_prepare.sh --only-dem    Only prepare GAMMA DEM.
  ./S1_gamma_prepare.sh --only-import Only import Sentinel-1 ZIPs and write SLC_tabs.
  ./S1_gamma_prepare.sh --check-only  Validate derived paths/ZIP discovery and write INPUT_MANIFEST.txt.
  ./S1_gamma_prepare.sh --help        Show this help.

Before running, normally edit only ISCE2_DIR, PROJECT_ROOT, REF and SEC in Section 0A.
SLC ZIPs, orbit directory and ISCE DEM root are derived automatically.
For cross-satellite pairs, use the default SECONDARY_IMPORT_MODE=auto or set it to independent.
TXT
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only-dem)
        RUN_IMPORT=0; RUN_DEM=1; shift ;;
      --only-import)
        RUN_IMPORT=1; RUN_DEM=0; shift ;;
      --check-only)
        CHECK_ONLY=1; RUN_IMPORT=1; RUN_DEM=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        exit 1 ;;
    esac
  done
}

main(){
  parse_args "$@"
  resolve_input_layout
  mkdir -p "$PROJECT_ROOT" "$WORK_ROOT" "$TAB_DIR" "$DEM_DIR" "$LOG_DIR"
  write_input_manifest

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ "$DEM_MODE" == "from_isce_dem" ]]; then
      local check_dem
      check_dem=$(find_isce_dem_file)
      log "Resolved ISCE DEM: $check_dem"
    fi
    log "CHECK_ONLY=1: configuration and input discovery passed; no GAMMA files were changed."
    exit 0
  fi

  if [[ "$RUN_IMPORT" -eq 1 ]]; then
    prepare_import
  else
    log "RUN_IMPORT=0; skip Sentinel-1 import."
  fi

  if [[ "$RUN_DEM" -eq 1 ]]; then
    prepare_gamma_dem
  else
    log "RUN_DEM=0; skip DEM preparation."
  fi

  write_summary
  log "Done. Next: edit/run the GAMMA pair-processing script."
}

main "$@"
