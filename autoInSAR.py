#!/usr/bin/env python3
"""
autoInSAR: Automated Sentinel-1 InSAR Processing Pipeline based on ISCE2
-----------------------------------------------------------------------

Description:
    This script provides a fully automated workflow for D-InSAR processing using Sentinel-1 data.
    It wraps the ISCE2 (topsApp.py) software and handles the entire lifecycle of interferometry:
    
    1. Search   : Auto-search SLCs from ASF API based on Event Date (Earthquake mode) or Manual Dates.
    2. Download : Automated sequential downloading of SLCs and verification.
    3. Orbit    : Auto-fetch Precision (POEORB) or Restituted (RESORB) orbit files with robust time-window matching.
    4. DEM      : Auto-download SRTMGL1 tiles and stitch them using ISCE's dem utilities.
    5. Config   : Auto-generation of standard ISCE XML configuration files (tops.xml, reference.xml, secondary.xml).
    6. Process  : Execution of the standard topsApp.py workflow (startup -> geocodeoffsets).
    7. Post-Proc: Python-based result extraction, cropping, decomposition (E/N/U), and visualization (Matplotlib).

Dependencies:
    - System: ISCE2 (v2.6+), wget
    - Python: numpy, matplotlib, osgeo (gdal), requests

Usage Examples:
    1. Earthquake Mode (Auto-search +/- 12 days):
       $ python autoInSAR.py --lon 40.7 --lat 13.6 --event_date 20251117 --platform S1A

    2. Manual Pair Mode (Specific dates):
       $ python autoInSAR.py --lon 40.7 --lat 13.6 --reference_date 20251113 --secondary_date 20251125

    3. Specify Relative Orbit (e.g., Track 14):
       $ python autoInSAR.py ... --rel_orbit 14

    4. Run specific step (e.g., Post-processing only):
       $ python autoInSAR.py --step post

Author:
    Mingjia Li

Date:
    February 2026

License:
    MIT License
    Copyright (c) 2026 Mingjia Li
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
"""

import os
import sys
import argparse
import subprocess
import json
import requests
import re
import shutil
import zipfile
import glob
import math
import time
from datetime import datetime, timedelta

# for post processing
try:
    import numpy as np
    from osgeo import gdal
    
    import matplotlib
    matplotlib.use('Agg') 
    import matplotlib.pyplot as plt
    from matplotlib.colors import LightSource
except ImportError as e:
    sys.exit(f"[!] Critical Error: Missing required libraries\n    Details: {e}\n ")

class AutoInSAR_Pipeline:
    def __init__(self, args):
        self.args = args
        self.work_dir = os.getcwd()
        self.api_url = "https://api.daac.asf.alaska.edu/services/search/param"
        
        # Initialize basic variables
        self.eq_date = args.event_date
        self.reference_date = args.reference_date
        self.secondary_date = args.secondary_date
        self.lat = args.lat
        self.lon = args.lon
        
        # Maps shorthands to API standards (Sentinel-1 series)
        platform_map = {
            "S1": "Sentinel-1",
            "S1A": "Sentinel-1A",
            "S1B": "Sentinel-1B",
            "S1C": "Sentinel-1C"
        }
        self.platform = platform_map.get(args.platform, args.platform)

        self.rel_orbit = int(args.rel_orbit) if args.rel_orbit else None
        
        # Result containers
        self.search_results = []
        self.target_orbit = None
        self.slc_file_list = None
        self.slc_url_list = None

    def run_command(self, cmd):
        """Generic command executor."""
        print(f"\n[Exec]: {cmd}")
        try:
            subprocess.run(cmd, shell=True, check=True)
        except subprocess.CalledProcessError:
            print(f"Error executing command: {cmd}")
            sys.exit(1)

    # --------------------------------------------------------------------------
    # Step 1: SLC Data Search
    # --------------------------------------------------------------------------
    def step_1_search_data(self):
        print("\n" + "="*50)
        print(">>> Step 1: Searching SLC Data from ASF")
        print("="*50)

        
        d = self.args.dlonlat
        min_lon = self.lon - d
        min_lat = self.lat - d
        max_lon = self.lon + d
        max_lat = self.lat + d
        bbox = f"{min_lon:.4f},{min_lat:.4f},{max_lon:.4f},{max_lat:.4f}" # Build Bbox
        print(f"[*] Bbox set to: {bbox} (Center: {self.lon}, {self.lat}, Buffer: {d})")

        query_time_ranges = []

        if self.reference_date and self.secondary_date:
            # Mode A: Specific Pair Mode (Search exact dates only)
            try:
                dt_s = datetime.strptime(self.reference_date, "%Y%m%d")
                dt_e = datetime.strptime(self.secondary_date, "%Y%m%d")
            except ValueError:
                print("[!] Error: Date format must be YYYYMMDD")
                sys.exit(1)
            
            print(f"[*] Date Mode: Manual Pair Selection")
            print(f"    - Date 1: {dt_s.date()}")
            print(f"    - Date 2: {dt_e.date()}")

            q1_start = dt_s.strftime("%Y-%m-%dT00:00:00.000Z")
            q1_end = (dt_s + timedelta(hours=23, minutes=59, seconds=59)).strftime("%Y-%m-%dT23:59:59.999Z")
            query_time_ranges.append((q1_start, q1_end))

            q2_start = dt_e.strftime("%Y-%m-%dT00:00:00.000Z")
            q2_end = (dt_e + timedelta(hours=23, minutes=59, seconds=59)).strftime("%Y-%m-%dT23:59:59.999Z")
            query_time_ranges.append((q2_start, q2_end))

        elif self.eq_date:
            # Mode B: Event Mode (Auto range +/- 12 days)
            try:
                eq_dt = datetime.strptime(self.eq_date, "%Y%m%d")
            except ValueError:
                print("[!] Error: Date format must be YYYYMMDD")
                sys.exit(1)
            
            dt_start = eq_dt - timedelta(days=12)
            dt_end = eq_dt + timedelta(days=12)
            
            t_start = dt_start.strftime("%Y-%m-%dT00:00:00.000Z")
            t_end = dt_end.strftime("%Y-%m-%dT23:59:59.999Z")
            
            print(f"[*] Date Mode: Earthquake Event ({eq_dt.date()}) -> Auto Range: {dt_start.date()} to {dt_end.date()}")
            query_time_ranges.append((t_start, t_end))
        
        else:
            print("[!] Error: Missing date arguments. Use --event_date OR --reference_date/--secondary_date.")
            sys.exit(1)

        # Execute Queries
        all_results = []
        print(f"[*] Querying ASF API ({len(query_time_ranges)} request(s))...")
        
        for idx, (t_start, t_end) in enumerate(query_time_ranges):
            params = {
                "platform": self.platform,
                "processingLevel": "SLC",
                "beamMode": "IW",
                "start": t_start,
                "end": t_end,
                "bbox": bbox,
                "output": "json",
                "maxResults": 200
            }
            if self.rel_orbit:
                params["relativeOrbit"] = self.rel_orbit

            try:
                if len(query_time_ranges) > 1:
                    print(f"    Running query {idx+1}/{len(query_time_ranges)} for range {t_start[:10]}...")
                
                response = requests.get(self.api_url, params=params, timeout=60)
                response.raise_for_status()
                data = json.loads(response.text)
                
                current_batch = []
                if isinstance(data, list) and len(data) > 0 and isinstance(data[0], list):
                    current_batch = data[0]
                elif isinstance(data, list):
                    current_batch = data
                
                if current_batch:
                    all_results.extend(current_batch)
                    
            except Exception as e:
                print(f"[!] API Request Failed for range {t_start}: {e}")

        # Remove Duplicates 
        unique_results = {}
        for item in all_results:
            key = item.get('sceneId', item.get('fileName'))
            unique_results[key] = item
        
        results_list = list(unique_results.values())

        if not results_list:
            print("[!] No results found.")
            sys.exit(0)

        print(f"[*] Found {len(results_list)} scenes total (merged).")

        # Orbit Analysis
        orbit_map = {} 
        for item in results_list:
            if 'relativeOrbit' in item:
                orb = int(item['relativeOrbit'])
                direction = item.get('flightDirection', 'UNKNOWN')
                if orb not in orbit_map:
                    orbit_map[orb] = direction

        found_orbits = sorted(list(orbit_map.keys()))
        
        if not found_orbits:
             print("[!] Error: Could not extract orbit information.")
             sys.exit(1)

        if self.rel_orbit:
            self.target_orbit = self.rel_orbit
            final_results = [x for x in results_list if int(x.get('relativeOrbit', -1)) == self.target_orbit]
        else:
            if len(found_orbits) == 1:
                self.target_orbit = found_orbits[0]
                direction = orbit_map[self.target_orbit]
                print(f"[*] Single orbit detected: {self.target_orbit} ({direction}). Proceeding automatically.")
                final_results = results_list
            else:
                print(f"[!] Multiple orbits found: {found_orbits}")
                print("    Please analyze which orbit fits best and run again with --rel_orbit <number>")
                for orb in found_orbits:
                    cnt = sum(1 for x in results_list if int(x.get('relativeOrbit', -1)) == orb)
                    direction = orbit_map.get(orb, 'UNKNOWN')
                    print(f"    Orbit {orb} ({direction}): {cnt} scenes")
                
                print("[!] Stopping process. Please specify an orbit.")
                sys.exit(0)
        
        # dates number check
        unique_dates = sorted(list(set([item.get('startTime', 'Unknown')[:10] for item in final_results])))
        
        if len(unique_dates) > 2:
            print("\n" + "!"*60)
            print(f"[!] AMBIGUITY ERROR: Found {len(unique_dates)} unique dates in the search window.")
            print(f"    Dates Found: {', '.join(unique_dates)}")
            print("-" * 60)
            print("    Standard InSAR processing requires exactly ONE pair (2 dates).")
            print("    Your search (likely --event_date mode) captured too many revisit cycles.")
            print("\n    >>> SOLUTIONS:")
            print("    1. Use --platform (e.g., S1A) to filter if S1A/S1B/S1C are mixed.")
            print(f"    2. Use manual pair selection instead of event mode:")
            print(f"       python run_insar_auto.py ... --reference_date {unique_dates[0].replace('-','')} --secondary_date {unique_dates[1].replace('-','')}")
            print("!"*60 + "\n")
            
            sys.exit(0)
        
        if len(unique_dates) < 2:
            print(f"[!] Error: Found only {len(unique_dates)} date ({unique_dates}). InSAR requires a pair.")
            sys.exit(0)

        # Save Results
        final_results.sort(key=lambda x: x['processingDate'])
        
        list_filename = f"list_{self.platform}_{self.target_orbit}.txt"
        url_filename = f"url_{self.platform}_{self.target_orbit}.txt"
        
        total_size = 0.0
        with open(list_filename, "w") as f_list, open(url_filename, "w") as f_url:
            for item in final_results:
                f_list.write(f"{item['fileName']}\n")
                f_url.write(f"{item['downloadUrl']}\n")
                total_size += float(item.get('sizeMB', 0))
        
        # Calculate and Save Spatial Extent 
        print("[*] Calculating spatial coverage from footprints...")
        min_lon, max_lon = float('inf'), float('-inf')
        min_lat, max_lat = float('inf'), float('-inf')
        
        for item in final_results:
            if 'stringFootprint' in item:
                footprint = item['stringFootprint']
                coordinates = re.findall(r"(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)", footprint)
                for lon_str, lat_str in coordinates:
                    lon, lat = float(lon_str), float(lat_str)
                    min_lon = min(min_lon, lon)
                    max_lon = max(max_lon, lon)
                    min_lat = min(min_lat, lat)
                    max_lat = max(max_lat, lat)

        extent_filename = "extent.txt"
        if min_lon != float('inf'):
            with open(extent_filename, "w") as f_ext:
                f_ext.write(f"{min_lat}\n")
                f_ext.write(f"{max_lat}\n")
                f_ext.write(f"{min_lon}\n")
                f_ext.write(f"{max_lon}\n")
            print(f"[*] Extent saved to {extent_filename}: Lat [{min_lat}, {max_lat}], Lon [{min_lon}, {max_lon}]")
        else:
            print("[!] Warning: Could not calculate extent (footprint data missing).")

        # Acquire SLC dates
        acquired_dates = [item.get('startTime', 'Unknown')[:10] for item in final_results]
        acquired_dates.sort()

        target_dir = orbit_map.get(self.target_orbit, 'UNKNOWN')
        print(f"[*] Search complete.")
        print(f"    - Target Orbit: {self.target_orbit} ({target_dir})")
        print(f"    - Scenes: {len(final_results)}")
        print(f"    - Dates : {', '.join(acquired_dates)}")
        print(f"    - Total Size: {total_size/1000:.2f} GB")
        print(f"    - File List saved to: {list_filename}")
        print(f"    - URL List saved to: {url_filename}")
        print(f"    - Extent File saved to: {extent_filename}")

        self.slc_file_list = list_filename
        self.slc_url_list = url_filename
        
        print("[*] Step 1 Search completed.")

    # --------------------------------------------------------------------------
    # Step 2: SLC Download
    # --------------------------------------------------------------------------
    def step_2_download_data(self):
        print("\n" + "="*50)
        print(">>> Step 2: Downloading SLC Data")
        print("="*50)
        
        # Check Credentials
        if not os.path.exists(os.path.expanduser("~/.netrc")):
            sys.exit("[!] Error: ~/.netrc missing. Please configure NASA Earthdata credentials.")

        if not self.slc_file_list:
            detected_list = self._auto_detect_list_file()
            
            if detected_list:
                detected_url = detected_list.replace("list_", "url_")
                if os.path.exists(detected_url):
                    self.slc_file_list = detected_list
                    self.slc_url_list = detected_url
                    print(f"[*] Auto-detected file pair: {self.slc_file_list}")
                else:
                    sys.exit(f"[!] Error: Found list file {detected_list} but missing {detected_url}")
            else:
                sys.exit("[!] Error: No matching 'list_*.txt' found. Check --rel_orbit or run Step 1.")

        # Prepare Directories
        slc_dir = os.path.join(self.work_dir, "SLC")
        unused_dir = os.path.join(self.work_dir, "unused")
        os.makedirs(slc_dir, exist_ok=True)
        os.makedirs(unused_dir, exist_ok=True)
        
        log_file = os.path.join(slc_dir, "download.log")

        # ZIP Verification 
        def is_valid_zip(path):
            if not os.path.exists(path): return False
            try:
                if not zipfile.is_zipfile(path): return False
                with zipfile.ZipFile(path) as zf:
                    return zf.testzip() is None
            except Exception:
                return False

        def log(msg):
            ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            full_msg = f"{ts} - {msg}"
            print(full_msg)
            with open(log_file, "a") as f:
                f.write(full_msg + "\n")

        # Process Download List
        print(f"[*] Reading list files...")
        with open(self.slc_file_list) as f_l, open(self.slc_url_list) as f_u:
            tasks = zip(f_l.read().splitlines(), f_u.read().splitlines())
            
        task_list = list(tasks)
        total = len(task_list)
        
        print(f"[*] Starting download loop for {total} files directly into '{slc_dir}/'...")

        for idx, (fname, url) in enumerate(task_list, 1):
            if not fname or not url: continue
            if not fname.endswith('.zip'): fname += '.zip'
            
            target_path = os.path.join(slc_dir, fname)
            
            print("-" * 40)
            print(f"[Progress: {idx}/{total}] Target: {fname}")

            if os.path.exists(target_path):
                print("    -> File exists locally. Verifying...")
                if is_valid_zip(target_path):
                    log(f"Skipping (Valid): {fname}")
                    continue
                else:
                    log(f"File corrupted. Moving to unused/: {fname}")
                    shutil.move(target_path, os.path.join(unused_dir, fname))

            # Download SLC files
            cmd = f"wget -c -q --show-progress -O {target_path} {url}"
            try:
                self.run_command(cmd)
            except Exception as e:
                log(f"Download Error for {fname}: {e}")
                continue

            # Post-Download Verification
            if is_valid_zip(target_path):
                log(f"Download Success & Verified: {fname}")
            else:
                log(f"Download Failed (Verification Error): {fname}")
                if os.path.exists(target_path):
                    shutil.move(target_path, os.path.join(unused_dir, fname))

        # Cleanup
        if os.path.exists(unused_dir):
            try:
                shutil.rmtree(unused_dir)
                print(f"    [+] Cleaned up temporary directory: {unused_dir}")
            except Exception as e:
                print(f"    [!] Warning: Failed to delete {unused_dir}: {e}")
                
        print(f"[*] Step 2 Download completed, files saved in: {slc_dir}")

    # --------------------------------------------------------------------------
    # Step 3: Orbit Download 
    # --------------------------------------------------------------------------
    def step_3_download_orbit(self):
        print("\n" + "="*50)
        print(">>> Step 3: Downloading Orbits (POEORB/RESORB)")
        print("="*50)
             
        # Ensure list files
        if not self.slc_file_list:
            self.slc_file_list = self._auto_detect_list_file()
            
            if self.slc_file_list:
                print(f"[*] Auto-detected SLC list: {self.slc_file_list}")
            else:
                print("[!] Error: No SLC list file found.")
                print("    Please run 'step 1' (search) first or check --rel_orbit.")
                sys.exit(1)
            
        orbit_dir = os.path.join(self.work_dir, "orbits")
        os.makedirs(orbit_dir, exist_ok=True)

        # Parse SLC dates from list file
        needed = {} 
        for line in open(self.slc_file_list):
            m = re.search(r'(S1[AB])_.*_(\d{8}T\d{6})_', line)
            if m: needed[(m.group(1), datetime.strptime(m.group(2), "%Y%m%dT%H%M%S"))] = True
        
        # Sort requests by date
        reqs = sorted(needed.keys(), key=lambda x: x[1])
        print(f"[*] Need orbits for {len(reqs)} SLCs.")

        # Phase 1: Try POEORB (Precise)
        poe_url = "https://s1qc.asf.alaska.edu/aux_poeorb/"
        candidates = self._fetch_orbit_candidates(poe_url, "POEORB")
        missing = []

        for p, dt in reqs:
            matches = sorted([c for c in candidates if c['p'] == p and c['s'] < dt < c['e']], 
                                 key=lambda x: x['s'])

            if matches:
                best = matches[len(matches)//2]
                dest = os.path.join(orbit_dir, best['file'])
                if not os.path.exists(dest):
                    self.run_command(f"wget -q -nc --show-progress -P {orbit_dir} {poe_url + best['file']}")
                else:
                    print(f"    -> Skipped (Exists): {best['file']}")
            else:
                missing.append((p, dt))

        # Phase 2: Try RESORB (Restituted) for any missing
        if missing:
            print(f"\n[*] Checking RESORB for {len(missing)} missing files...")
            res_url = "https://s1qc.asf.alaska.edu/aux_resorb/"
            candidates = self._fetch_orbit_candidates(res_url, "RESORB")
            
            for p, dt in missing:
                matches = sorted([c for c in candidates if c['p'] == p and c['s'] < dt < c['e']], 
                                 key=lambda x: x['s'])
                
                if matches:
                    best = matches[len(matches)//2]
                    dest = os.path.join(orbit_dir, best['file'])
                    if not os.path.exists(dest):
                        print(f"[*] Found RESORB: {best['file']}")
                        self.run_command(f"wget -q -nc --show-progress -P {orbit_dir} {res_url + best['file']}")
                    else:
                        print(f"    -> Skipped (Exists): {best['file']}")
                else:
                    print(f"[!] CRITICAL: No valid orbit found for {p} {dt}")
        
        print(f"[*] Step 3 Orbit completed, files saved in: {orbit_dir}")

    # --------------------------------------------------------------------------
    # Step 4: DEM Download
    # --------------------------------------------------------------------------
    def step_4_download_dem(self):
        print("\n" + "="*50)
        print(">>> Step 4: Preparing DEM")
        print("="*50)
        
        extent_file = "extent.txt"
        if not os.path.exists(extent_file):
            sys.exit("[!] Error: 'extent.txt' not found. Please run Step 1 first.")
            
        # Read Extent from file
        try:
            with open(extent_file, 'r') as f:
                lines = f.readlines()
                min_lat_f = float(lines[0].strip())
                max_lat_f = float(lines[1].strip())
                min_lon_f = float(lines[2].strip())
                max_lon_f = float(lines[3].strip())
        except Exception as e:
            sys.exit(f"[!] Error reading extent.txt: {e}")

        # Calculate Integer Boundaries (Floor logic)
        lat_0 = int(math.floor(min_lat_f))
        lat_1 = int(math.floor(max_lat_f))
        lon_0 = int(math.floor(min_lon_f))
        lon_1 = int(math.floor(max_lon_f))
        
        print(f"[*] Extent Float: Lat [{min_lat_f}, {max_lat_f}], Lon [{min_lon_f}, {max_lon_f}]")
        print(f"[*] Extent Int  : Lat [{lat_0}, {lat_1}], Lon [{lon_0}, {lon_1}]")

        dem_dir = os.path.join(self.work_dir, "DEM")
        os.makedirs(dem_dir, exist_ok=True)
        
        # Download Tiles
        print("[*] Downloading SRTMGL1 tiles...")
        base_url = "https://step.esa.int/auxdata/dem/SRTMGL1"
        
        count = 0
        for lat in range(lat_0, lat_1 + 1):
            for lon in range(lon_0, lon_1 + 1):
                ns = 'N' if lat >= 0 else 'S'
                ew = 'E' if lon >= 0 else 'W'
                fname = f"{ns}{abs(lat):02d}{ew}{abs(lon):03d}.SRTMGL1.hgt.zip"
                
                dest_path = os.path.join(dem_dir, fname)
                
                if not os.path.exists(dest_path):
                    cmd = f"wget -q -nc -P {dem_dir} {base_url}/{fname}"
                    subprocess.run(cmd, shell=True)
                    
                    if os.path.exists(dest_path):
                        print(f"    [+] Downloaded: {fname}")
                        count += 1
                else:
                    print(f"    [.] Skipped (Exists): {fname}")
                    
        print(f"[*] Download loop finished. New files downloaded: {count}")

        # Stitch DEM (Call dem.py)
        if shutil.which("dem.py") is None:
            print("\n[!] Error: 'dem.py' command not found in system PATH!")
            print("    This step requires ISCE2 software environment.")
            print("    Please load your ISCE2 environment and try again.")
            sys.exit(1)
            
        cmd_stitch = f"dem.py -a stitch -b {lat_0} {lat_1 + 1} {lon_0} {lon_1 + 1} -s 1 -r -c -l -f --filling_value 0"
        
        print(f"[*] Stitching DEM in {dem_dir}...")
        
        cwd = os.getcwd()
        try:
            os.chdir(dem_dir)
            self.run_command(cmd_stitch)
        except Exception as e:
            print(f"[!] Error during DEM stitching: {e}")
            sys.exit(1)
        finally:
            os.chdir(cwd)
            
        print(f"[*] Step 4 Dem completed, files saved in: {dem_dir}")

    # --------------------------------------------------------------------------
    # Step 5: XML Generation 
    # --------------------------------------------------------------------------
def step_5_generate_xml(self):
        print("\n" + "="*50)
        print(">>> Step 5: Generating ISCE XML Files")
        print("="*50)

        process_dir = os.path.join(self.work_dir, "process")
        os.makedirs(process_dir, exist_ok=True)

        # Ensure list file 
        if not self.slc_file_list:
            self.slc_file_list = self._auto_detect_list_file()
            
            if self.slc_file_list:
                print(f"[*] Auto-detected SLC list: {self.slc_file_list}")
            else:
                sys.exit("[!] Error: No matching SLC list file found. Please run Step 1 first.")
            
        slc_groups = {}
        date_pattern = re.compile(r'S1[A-D]_.*_(\d{8})T')
        
        with open(self.slc_file_list, 'r') as f:
            for line in f:
                fname = line.strip()
                if not fname: continue
                if not fname.endswith('.zip'): fname += '.zip'
                
                m = date_pattern.search(fname)
                if m:
                    date_key = m.group(1)
                    if date_key not in slc_groups:
                        slc_groups[date_key] = []
                    slc_groups[date_key].append(fname)
        
        # Sort Dates
        dates = sorted(slc_groups.keys())
        if len(dates) != 2:
            print(f"[!] Error: Found {len(dates)} unique dates in list: {dates}")
            sys.exit("[!] Standard InSAR requires exactly 2 dates (Reference & Secondary).")
            
        ref_date, sec_date = dates[0], dates[1]
        ref_files = slc_groups[ref_date]
        sec_files = slc_groups[sec_date]
        
        print(f"[*] Reference Date: {ref_date} ({len(ref_files)} files)")
        print(f"[*] Secondary Date: {sec_date} ({len(sec_files)} files)")
        
        # Helper to format list string
        def fmt_safe_paths(file_list):
            paths = [os.path.join(self.work_dir, "SLC", f) for f in file_list]
            return str(paths).replace('"', "'")

        orbit_dir = os.path.join(self.work_dir, "orbits")

        # Write reference.xml
        ref_xml = f"""<component name="reference">
    <property name="orbit directory">{orbit_dir}</property>
    <property name="output directory">./reference</property>
    <property name="safe">{fmt_safe_paths(ref_files)}</property>
</component>
"""
        with open(os.path.join(process_dir, "reference.xml"), "w") as f:
            f.write(ref_xml)

        # Write secondary.xml
        sec_xml = f"""<component name="secondary">
    <property name="orbit directory">{orbit_dir}</property>
    <property name="output directory">./secondary</property>
    <property name="safe">{fmt_safe_paths(sec_files)}</property>
</component>
"""
        with open(os.path.join(process_dir, "secondary.xml"), "w") as f:
            f.write(sec_xml)

        # Auto-detect DEM file
        dem_candidates = glob.glob(os.path.join("DEM", "*.dem.wgs84"))
        if not dem_candidates:
            sys.exit("[!] Error: No *.dem.wgs84 file found in DEM/ directory.")
        
        dem_name = os.path.basename(dem_candidates[0])
        
        dem_path = os.path.join(self.work_dir, "DEM", dem_name)
        print(f"[*] Found DEM: {dem_path}")

        # Calculate ROI
        roi_string = "[]" 
        
        if self.lat is not None and self.lon is not None:
            d = self.args.dlonlat
            min_lat = self.lat - d
            max_lat = self.lat + d
            min_lon = self.lon - d
            max_lon = self.lon + d
            
            roi_string = f"[{min_lat:.4f}, {max_lat:.4f}, {min_lon:.4f}, {max_lon:.4f}]"
            print(f"[*] Region of Interest set to: {roi_string}")
        else:
            print("[*] No center coordinates provided. Region of Interest set to [] (Full Frame).")

        # Write tops.xml
        tops_xml = f"""<topsApp>
    <component name="topsinsar">
        <property name="Sensor name">SENTINEL1</property>
        <component name="reference">
            <catalog>reference.xml</catalog>
        </component>
        <component name="secondary">
            <catalog>secondary.xml</catalog>
        </component>
        <property name="demFilename">{dem_path}</property>
        <property name="swaths">[1,2,3]</property>
        <property name="range looks">20</property>
        <property name="azimuth looks">5</property>
        <property name="region of interest">{roi_string}</property>
        <property name="do unwrap">True</property>
        <property name="unwrapper name">snaphu_mcf</property>
        <property name="do denseoffsets">True</property>
        <property name="filter strength">0.4</property>
        <property name="useGPU">True</property>
    </component>
</topsApp>
"""
        with open(os.path.join(process_dir, "tops.xml"), "w") as f:
            f.write(tops_xml)
            
        print(f"[*] Step 5 Xml completed, files generated in: {process_dir}")
        
    # --------------------------------------------------------------------------
    # Step 6: ISCE Processing
    # --------------------------------------------------------------------------
    def step_6_process_isce(self):
        print("\n" + "="*50)
        print(">>> Step 6: Running ISCE topsApp.py")
        print("="*50)

        # Check Environment    
        if shutil.which("topsApp.py") is None:
            print("[!] Error: 'topsApp.py' command not found in system PATH!")
            print("    This step requires ISCE2 software environment.")
            print("    Please load your ISCE2 environment and try again.")
            sys.exit(1)

        process_dir = os.path.join(self.work_dir, "process")
        if not os.path.exists(process_dir):
            sys.exit("[!] Error: 'process' directory not found. Please run Step 5 first.")

        # Timer
        start_time = time.time()
        start_str = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(start_time))
        print(f"[*] Processing started at: {start_str}")
        print(f"[*] Switching to directory: {process_dir}")
        print("[*] Executing: topsApp.py tops.xml --steps --start='startup' --end='geocodeoffsets'")
        print("    (This may take several hours depending on your hardware...)")

        cwd = os.getcwd()
        try:
            os.chdir(process_dir)
            
            # The standard full InSAR processing command
            cmd = "topsApp.py tops.xml --steps --start='startup' --end='geocodeoffsets'"
            self.run_command(cmd)
            
        except KeyboardInterrupt:
            print("\n[!] Process interrupted by user.")
            sys.exit(1)
        except Exception as e:
            print(f"[!] Error during ISCE processing: {e}")
            sys.exit(1)
        finally:
            os.chdir(cwd)

        # Stop Timer
        end_time = time.time()
        end_str = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(end_time))
        duration = end_time - start_time
        
        # Format duration
        duration_str = str(timedelta(seconds=int(duration)))
        
        print("-" * 50)
        print(f"[*] Step 6 ISCE finished, files generated in: {process_dir}")
        print(f"    - Start Time: {start_str}")
        print(f"    - End Time  : {end_str}")
        print(f"    - Duration  : {duration_str}")
        print("-" * 50)
        

    # --------------------------------------------------------------------------
    # Step 7: Post Processing 
    # --------------------------------------------------------------------------
    def step_7_post_process(self):
        print("\n" + "="*50)
        print(">>> Step 7: Result Extraction & Plotting")
        print("="*50)

        # Setup Directories
        merged_dir = os.path.join(self.work_dir, "process", "merged")
        result_dir = os.path.join(self.work_dir, "results")
        os.makedirs(result_dir, exist_ok=True)
        
        if not os.path.exists(merged_dir):
            sys.exit(f"[!] Error: Merged directory not found: {merged_dir}")

        print(f"[*] Reading results from: {merged_dir}")
        print(f"[*] Saving GRD outputs to: {result_dir}")
        print(f"[*] Saving Plots to     : {plot_dir}")
        
        # extract orbit number
        orbit_num = "UNKNOWN"
        try:
            if self.rel_orbit:
                orbit_num = str(self.rel_orbit)
                print(f"[*] Using specified Orbit Number: {orbit_num}")
            else:
                target_list = self._auto_detect_list_file()
                if target_list:
                    m = re.search(r'_(\d+)\.txt$', target_list)
                    if m:
                        orbit_num = m.group(1)
                        print(f"[*] Detected Orbit Number from file ({target_list}): {orbit_num}")
        except Exception as e:
            print(f"[!] Warning: Could not detect orbit number: {e}")
            
        # Load & Process Data 
        print("[*] Processing LOS...")
        raw_unw, geo_info = self._read_gdal_file(merged_dir, "filt_topophase.unw.geo", band_idx=2)
        if raw_unw is None: sys.exit("[!] Critical: No unwrapped phase found.")
        data_los = raw_unw * -0.0044

        print("[*] Processing Coherence...")
        data_coh, _ = self._read_gdal_file(merged_dir, "phsig.cor.geo", band_idx=1)

        print("[*] Processing Geometry...")
        data_look, _ = self._read_gdal_file(merged_dir, "los.rdr.geo", band_idx=1) 
        raw_az, _    = self._read_gdal_file(merged_dir, "los.rdr.geo", band_idx=2) 
        data_az = -1 * raw_az - 180

        print("[*] Processing Offsets...")
        raw_off_az, _ = self._read_gdal_file(merged_dir, "filt_dense_offsets.bil.geo", band_idx=1)
        raw_off_rg, _ = self._read_gdal_file(merged_dir, "filt_dense_offsets.bil.geo", band_idx=2)
        data_off_rg = raw_off_rg * -2.32956 if raw_off_rg is not None else None
        data_off_az = raw_off_az * 13.9332  if raw_off_az is not None else None

        print("[*] Processing SNR...")
        data_snr, _ = self._read_gdal_file(merged_dir, "dense_offsets_snr.bil.geo", band_idx=1)
        
        data_wrap = (raw_unw + np.pi) % (2 * np.pi) - np.pi

        # Masking & Cropping (ROI)
        lons, lats, gt, proj = geo_info
        
        if self.lat is not None and self.lon is not None:
            d = self.args.dlonlat
            min_lon_t, max_lon_t = self.lon - d, self.lon + d
            min_lat_t, max_lat_t = self.lat - d, self.lat + d
            x_idxs = np.where((lons >= min_lon_t) & (lons <= max_lon_t))[0]
            y_idxs = np.where((lats <= max_lat_t) & (lats >= min_lat_t))[0]
            
            if len(x_idxs) > 0 and len(y_idxs) > 0:
                x_start, x_end = x_idxs[0], x_idxs[-1] + 1
                y_start, y_end = y_idxs[0], y_idxs[-1] + 1
                print(f"[*] Cropping to: Lon[{min_lon_t:.2f}, {max_lon_t:.2f}], Lat[{min_lat_t:.2f}, {max_lat_t:.2f}]")
            else:
                x_start, x_end, y_start, y_end = 0, len(lons), 0, len(lats)
        else:
            x_start, x_end, y_start, y_end = 0, len(lons), 0, len(lats)

        def crop(arr):
            if arr is None: return None
            return arr[y_start:y_end, x_start:x_end].copy()

        c_los  = crop(data_los)
        c_los_save  = crop(data_los)
        c_coh  = crop(data_coh)
        c_look = crop(data_look)
        c_az   = crop(data_az)
        c_wrap = crop(data_wrap)
        c_wrap_save  = crop(data_wrap)
        c_off_rg = crop(data_off_rg)
        c_off_az = crop(data_off_az)
        c_snr    = crop(data_snr)
        
        c_lons = lons[x_start:x_end]
        c_lats = lats[y_start:y_end]
        
        # Masking
        coh_thresh = 0.3
        mask_bad1 = (c_look == 0) | np.isnan(c_los)
        mask_bad2 = (c_coh < coh_thresh) | (c_look == 0) | np.isnan(c_los)
        
        c_los[mask_bad1] = np.nan
        c_wrap[mask_bad1] = np.nan
        c_los_save[mask_bad2] = np.nan
        c_wrap_save[mask_bad2] = np.nan
        if c_off_rg is not None: c_off_rg[mask_bad1] = np.nan
        if c_off_az is not None: c_off_az[mask_bad1] = np.nan
        if c_snr is not None: c_snr[c_look == 0] = np.nan

        # Decomposition & Calculation
        print("[*] Calculating E/N/U decomposition...")
        r_az = np.deg2rad(c_az)
        r_look = np.deg2rad(c_look)
        
        c_E = -np.sin(r_az) * np.sin(r_look)
        c_N = -np.cos(r_az) * np.sin(r_look)
        c_U = np.cos(r_look)
        
        c_E[mask_bad1] = np.nan
        c_N[mask_bad1] = np.nan
        c_U[mask_bad1] = np.nan

        # Calculate Mean Azimuth for plotting
        valid_mask = (c_az != 0) & (np.abs(c_az) != 180) & (~np.isnan(c_az))
        if np.any(valid_mask):
            mean_az = np.nanmean(c_az[valid_mask])
        else:
            mean_az = 0 
        print(f"[*] Mean Valid Azimuth: {mean_az:.2f} deg")

        # Save Results
        crop_geo_info = (c_lons, c_lats, gt, proj)
        
        self._save_grd(result_dir, "los_disp.grd", c_los_save, crop_geo_info)
        self._save_grd(result_dir, "coherence.grd", c_coh, crop_geo_info)
        self._save_grd(result_dir, "wrap_phase.grd", c_wrap_save, crop_geo_info)
        self._save_grd(result_dir, "vec_E.grd", c_E, crop_geo_info)
        self._save_grd(result_dir, "vec_N.grd", c_N, crop_geo_info)
        self._save_grd(result_dir, "vec_U.grd", c_U, crop_geo_info)
        
        if c_off_rg is not None: self._save_grd(result_dir, "offset_range.grd", c_off_rg, crop_geo_info)
        if c_off_az is not None: self._save_grd(result_dir, "offset_azimuth.grd", c_off_az, crop_geo_info)
        if c_snr is not None:    self._save_grd(result_dir, "snr.grd", c_snr, crop_geo_info)

        # Visualization
        direction_str = "asc" if mean_az >= 0 else "des"
        plot_folder_name = f"plot_{direction_str}_{orbit_num}"
        plot_dir = os.path.join(result_dir, plot_folder_name)
        
        os.makedirs(plot_dir, exist_ok=True)
        print(f"[*] Generating Plots in: {plot_dir}")
        
        extent = [c_lons[0], c_lons[-1], c_lats[-1], c_lats[0]]

        vmin, vmax = self._get_robust_clim(c_los, symmetric=True)
        
        self._plot_single(plot_dir, c_los, "LOS Displacement (m)", "los_disp.png", "jet", extent, mean_az, clim=(vmin, vmax), arrow_mode='both')
        self._plot_single(plot_dir, c_wrap, "Wrapped Phase (rad)", "wrap_phase.png", "hsv", extent, mean_az, clim=(-np.pi, np.pi))
        self._plot_single(plot_dir, c_coh, "Coherence", "coherence.png", "gray", extent, mean_az, clim=(0, 1))
        self._plot_single(plot_dir, c_off_rg, "Range Offset (m)", "offset_range.png", "jet", extent, mean_az, clim=(vmin, vmax), arrow_mode='range')
        self._plot_single(plot_dir, c_off_az, "Azimuth Offset (m)", "offset_azimuth.png", "jet", extent, mean_az, clim=(vmin, vmax), arrow_mode='azimuth')
        self._plot_single(plot_dir, c_snr, "SNR", "snr.png", "magma", extent, mean_az)

        # Summary Plot 
        print("[*] Generating Summary Plot...")
        fig, axes = plt.subplots(2, 2, figsize=(16, 12))
        
        # LOS
        vmin, vmax = self._get_robust_clim(c_los, symmetric=True)
        im1 = axes[0, 0].imshow(c_los, cmap='jet', extent=extent, vmin=vmin, vmax=vmax)
        axes[0, 0].set_title(f'LOS Displacement')
        plt.colorbar(im1, ax=axes[0, 0])
        
        # Wrap
        im2 = axes[0, 1].imshow(c_wrap, cmap='hsv', extent=extent, vmin=-np.pi, vmax=np.pi)
        axes[0, 1].set_title('Wrapped Phase')
        plt.colorbar(im2, ax=axes[0, 1])
        
        # Range Offset
        if c_off_rg is not None:
            vmin, vmax = self._get_robust_clim(c_off_rg, symmetric=True)
            im3 = axes[1, 0].imshow(c_off_rg, cmap='jet', extent=extent, vmin=vmin, vmax=vmax)
            axes[1, 0].set_title(f'Range Offset')
            plt.colorbar(im3, ax=axes[1, 0])
        
        # Azimuth Offset
        if c_off_az is not None:
            vmin, vmax = self._get_robust_clim(c_off_az, symmetric=True)
            im4 = axes[1, 1].imshow(c_off_az, cmap='jet', extent=extent, vmin=vmin, vmax=vmax)
            axes[1, 1].set_title(f'Azimuth Offset')
            plt.colorbar(im4, ax=axes[1, 1])

        if self.lat and self.lon:
            for ax in axes.flat:
                ax.scatter(self.lon, self.lat, c='red', marker='*', s=200, edgecolors='black')

        plt.tight_layout()
        summary_path = os.path.join(plot_dir, "summary_plot.png")
        plt.savefig(summary_path, dpi=300)
        plt.close()
        
        print(f"[*] Step 7 Post-processing finished, results generated in '{result_dir}'")
    
    # --------------------------------------------------------------------------
    # Helper Methods
    # --------------------------------------------------------------------------
    def _read_gdal_file(self, merged_dir, fname, band_idx=1):
        """read GDAL file"""
        path = os.path.join(merged_dir, fname)
        if not os.path.exists(path):
            print(f"[!] Warning: File not found: {fname}")
            return None, None
        
        ds = gdal.Open(path, gdal.GA_ReadOnly)
        if not ds: return None, None
        
        gt = ds.GetGeoTransform()
        proj = ds.GetProjection()
        width = ds.RasterXSize
        height = ds.RasterYSize
        data = ds.GetRasterBand(band_idx).ReadAsArray()
        
        min_lon = gt[0]
        max_lon = gt[0] + width * gt[1]
        max_lat = gt[3]
        min_lat = gt[3] + height * gt[5]
        
        lons = np.linspace(min_lon, max_lon, width)
        lats = np.linspace(max_lat, min_lat, height)
        
        ds = None 
        return data, (lons, lats, gt, proj)

    def _save_grd(self, result_dir, out_name, data, geo_info):
        """save file in GMT GRD format"""
        lons_cut, lats_cut, gt_orig, proj = geo_info
        new_gt = list(gt_orig)
        new_gt[0] = lons_cut[0]
        new_gt[3] = lats_cut[0]
        
        rows, cols = data.shape
        mem_driver = gdal.GetDriverByName('MEM')
        mem_ds = mem_driver.Create('', cols, rows, 1, gdal.GDT_Float32)
        mem_ds.SetGeoTransform(new_gt)
        mem_ds.SetProjection(proj)
        mem_ds.GetRasterBand(1).WriteArray(data)
        mem_ds.GetRasterBand(1).SetNoDataValue(np.nan)
        
        driver = gdal.GetDriverByName('GMT')
        out_path = os.path.join(result_dir, out_name)
        if os.path.exists(out_path): os.remove(out_path)
        
        dst_ds = driver.CreateCopy(out_path, mem_ds, 0)
        mem_ds = None
        dst_ds = None 
        
        # Cleanup XML
        aux_xml = out_path + ".aux.xml"
        if os.path.exists(aux_xml):
            try: os.remove(aux_xml)
            except OSError: pass

        print(f"    -> Saved GRD: {out_name}")

    def _get_robust_clim(self, data, symmetric=True):
        """get xlim/ylim for plot"""
        if data is None: return None, None
        valid_data = data[~np.isnan(data)]
        if len(valid_data) == 0: return -0.1, 0.1
        
        abs_data = np.abs(valid_data)
        max_val = np.nanmax(abs_data)
        
        if max_val <= 10.0:
            limit = max_val * 1.1
        else:
            limit = np.nanpercentile(abs_data, 99.9) * 1.2
        if limit < 0.05: limit = 0.05

        if symmetric:
            return -limit, limit
        else:
            return np.nanpercentile(valid_data, 2), np.nanpercentile(valid_data, 98)

    def _draw_arrows(self, ax, arrow_mode, mean_az):
        """draw arrow"""
        if not arrow_mode: return
        
        anchor_x, anchor_y = 0.80, 0.20
        flight_screen_angle = np.radians(180 - mean_az)
        scan_screen_angle = np.radians(90 - mean_az)
        
        len_flight = 0.12
        len_scan = 0.06
        
        if arrow_mode in ['both', 'azimuth']:
            dx = len_flight * np.cos(flight_screen_angle)
            dy = len_flight * np.sin(flight_screen_angle)
            ax.arrow(anchor_x, anchor_y, dx, dy, transform=ax.transAxes,
                     color='k', width=0.005, head_width=0.02, head_length=0.02, zorder=10)
            t_x = anchor_x + dx * 1.3
            t_y = anchor_y + dy * 1.3
            ax.text(t_x, t_y, "Azimuth", transform=ax.transAxes, 
                    ha='center', va='center', fontsize=12, fontweight='bold', color='k')
        
        if arrow_mode in ['both', 'range']:
            dx = len_scan * np.cos(scan_screen_angle)
            dy = len_scan * np.sin(scan_screen_angle)
            ax.arrow(anchor_x, anchor_y, dx, dy, transform=ax.transAxes,
                     color='k', width=0.010, head_width=0.02, head_length=0.02, zorder=10)
            t_x = anchor_x + dx * 2.0
            t_y = anchor_y + dy * 2.0
            ax.text(t_x, t_y, "Look", transform=ax.transAxes, 
                    ha='center', va='center', fontsize=12, fontweight='bold', color='k')

    def _plot_single(self, plot_dir, data, title, fname, cmap, extent, mean_az, clim=None, arrow_mode=None):
        """plot single figure for each data"""
        if data is None: return
        
        # Determine clim 
        if clim is None:
            if 'Coherence' in title:
                vmin, vmax = 0, 1
            elif 'SNR' in title:
                vmin, vmax = 0, np.nanpercentile(data, 98)
            else:
                vmin, vmax = self._get_robust_clim(data, symmetric=True)
        else:
            vmin, vmax = clim
            
        plt.figure(figsize=(10, 8))
        plt.imshow(data, cmap=cmap, extent=extent, vmin=vmin, vmax=vmax)
        plt.colorbar(label=title)
        plt.title(title, fontsize=14)
        plt.xlabel("Longitude")
        plt.ylabel("Latitude")
        
        if self.lat and self.lon:
            plt.scatter(self.lon, self.lat, c='red', marker='*', s=300, edgecolors='black')
        
        if arrow_mode:
            self._draw_arrows(plt.gca(), arrow_mode, mean_az)

        save_path = os.path.join(plot_dir, fname)
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        plt.close()
        print(f"    -> Saved Plot: {fname} (Range: {vmin:.3f} ~ {vmax:.3f})")
        
    def _fetch_orbit_candidates(self, url, otype):
        """ Fetch and parse orbit file list from ASF. """
        print(f"    -> Fetching index from {url} ...")
        try: 
            txt = requests.get(url, timeout=60).text
        except Exception as e: 
            print(f"[!] Network error: {e}")
            return []
        
        # Regex to match filename parts: Platform, GenTime, Start, End
        pat = re.compile(fr'(S1[AB])_OPER_AUX_{otype}_OPOD_(\d{{8}}T\d{{6}})_V(\d{{8}}T\d{{6}})_(\d{{8}}T\d{{6}})\.EOF')
        
        cands = []
        # Find all .EOF files first, then parse details
        for fname in re.findall(fr'S1[AB]_OPER_AUX_{otype}_OPOD_[A-Z0-9_]+\.EOF', txt):
            m = pat.match(fname)
            if m:
                cands.append({
                    'file': fname, 
                    'p': m.group(1),                  # Platform (S1A/S1B)
                    'gen': m.group(2),                # Generation Time
                    's': datetime.strptime(m.group(3), "%Y%m%dT%H%M%S"), # Start
                    'e': datetime.strptime(m.group(4), "%Y%m%dT%H%M%S")  # End
                })
        return cands
        
    def _auto_detect_list_file(self):
        """ Search list file, from orbit->platform->write time. """

        cands = glob.glob("list_*.txt")
        if not cands:
            return None
            
        # orbit number
        if self.rel_orbit:
            orbit_cands = [f for f in cands if f"_{self.rel_orbit}.txt" in f]
            if orbit_cands:
                cands = orbit_cands
            else:
                print(f"[!] Warning: Specified orbit {self.rel_orbit} not found in local lists.")
                return None

        # platform 
        if len(cands) > 1:
            plat_cands = [f for f in cands if self.platform in f]
            if plat_cands:
                cands = plat_cands
        
        # write time
        cands.sort(key=os.path.getmtime, reverse=True)
        
        return cands[0]

def main():
    parser = argparse.ArgumentParser(description="Auto InSAR Processing Pipeline")
    
    # Coordinates
    parser.add_argument("--lon", type=float, help="Event Center Longitude")
    parser.add_argument("--lat", type=float, help="Event Center Latitude")
    
    # Dates (YYYYMMDD)
    parser.add_argument("--event_date", type=str, help="Event Date (YYYYMMDD). Auto search +/- 12 days.")
    parser.add_argument("--reference_date", type=str, help="Manual Reference Date (YYYYMMDD)")
    parser.add_argument("--secondary_date", type=str, help="Manual Secondary Date (YYYYMMDD)")
    
    # Platform
    parser.add_argument("--platform", type=str, default="Sentinel-1", 
                        choices=["Sentinel-1", "Sentinel-1A", "Sentinel-1B", "Sentinel-1C",
                                 "S1", "S1A", "S1B", "S1C"],
                        help="Satellite Platform")
    
    # Orbit
    parser.add_argument("--rel_orbit", type=str, help="Relative Orbit Number (Optional).")
    parser.add_argument("--dlonlat", type=float, default=0.2, help="Search buffer in degrees (Default: 0.2)")
    
    # Steps
    parser.add_argument("--step", type=str, default="all",
                        choices=["search", "download", "orbit", "dem", "xml", "isce", "post", "all"],
                        help="Execution step")

    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)
        
    args = parser.parse_args()
    
    pipeline = AutoInSAR_Pipeline(args)
    
    if args.step == "search" or args.step == "all":
        pipeline.step_1_search_data()
    
    if args.step == "download" or args.step == "all":
        pipeline.step_2_download_data()
        
    if args.step == "orbit" or args.step == "all":
        pipeline.step_3_download_orbit()
        
    if args.step == "dem" or args.step == "all":
        pipeline.step_4_download_dem()
        
    if args.step == "xml" or args.step == "all":
        pipeline.step_5_generate_xml()
        
    if args.step == "isce" or args.step == "all":
        pipeline.step_6_process_isce()
        
    if args.step == "post" or args.step == "all":
        pipeline.step_7_post_process()
        
if __name__ == "__main__":
    main()