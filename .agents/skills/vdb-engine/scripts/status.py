#!/usr/bin/env python3
"""
VDB Engine Skill - Status Checker
Run from project root: python3 .agents/skills/vdb-engine/status.py
"""

import subprocess
import os
import sys

PROJECT_ROOT = r'D:\veritabani'

def run(cmd, cwd=None):
    try:
        result = subprocess.run(cmd, shell=True, cwd=cwd or PROJECT_ROOT, 
                              capture_output=True, text=False, timeout=120)
        stdout = result.stdout.decode('cp1254', errors='replace') if result.stdout else ''
        stderr = result.stderr.decode('cp1254', errors='replace') if result.stderr else ''
        return result.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"

def check_build():
    """Check if executables exist and are recent"""
    exe_files = {
        'sqltest.exe': 'Main test suite',
        'vdbapi.dll': 'C API DLL',
        'cdc_test.exe': 'CDC/TimeTravel test',
    }
    print("=== BUILD ARTIFACTS ===")
    for f, desc in exe_files.items():
        path = os.path.join(PROJECT_ROOT, f)
        if os.path.exists(path):
            size = os.path.getsize(path)
            mtime = os.path.getmtime(path)
            print(f"  [OK] {f} ({size:,} bytes) - {desc}")
        else:
            print(f"  [MISSING] {f} - {desc} (NOT BUILT)")

def run_tests():
    """Run sqltest and parse results"""
    print("\n=== TEST SUITE ===")
    code, out, err = run("sqltest.exe")
    if code == 0:
        # Parse last line
        for line in out.strip().split('\n')[-5:]:
            if 'SONUC:' in line or 'gecen' in line:
                print(f"  {line.strip()}")
                break
        if 'TUM SQL TESTLERI GECTI' in out:
            print("  [PASS] ALL TESTS PASSED")
        else:
            print("  [WARN] Tests ran but check output")
    else:
        print(f"  [FAIL] Test failed (exit {code})")
        print(err[-500:] if err else out[-500:])

def check_git_status():
    """Show git status if available"""
    print("\n=== GIT STATUS ===")
    code, out, err = run("git status --short")
    if code == 0 and out.strip():
        for line in out.strip().split('\n')[:20]:
            print(f"  {line}")
        if len(out.strip().split('\n')) > 20:
            print(f"  ... and {len(out.strip().split('\n')) - 20} more files")
    elif code == 0:
        print("  [CLEAN] Working tree clean")
    else:
        print("  (not a git repo or git not available)")

def show_roadmap_next():
    """Show next roadmap items from yol_haritasi.md"""
    print("\n=== NEXT ROADMAP ITEMS ===")
    roadmap_path = os.path.join(PROJECT_ROOT, 'yol_haritasi.md')
    if os.path.exists(roadmap_path):
        with open(roadmap_path, 'r', encoding='utf-8') as f:
            content = f.read()
        # Find items not marked ✅ BITTI
        in_table = False
        for line in content.split('\n'):
            if '├──────┼' in line and 'Özellik' in line:
                in_table = True
                continue
            if in_table and '└──────┴' in line:
                break
            if in_table and '│' in line and '✅ BITTI' not in line and ('R-' in line or '│' in line):
                parts = [p.strip() for p in line.split('│')]
                if len(parts) >= 4 and parts[1].startswith('R-'):
                    print(f"  [TODO] {parts[1]}: {parts[2][:60]}... ({parts[3]})")

def main():
    print("[VDB] Engine Status Check")
    print(f"[DIR] Project: {PROJECT_ROOT}")
    
    check_build()
    run_tests()
    check_git_status()
    show_roadmap_next()
    
    print("\n=== QUICK COMMANDS ===")
    print("  Build all:     lazbuild sqltest.lpi && lazbuild vdbapi.lpi")
    print("  Run tests:     ./sqltest.exe")
    print("  CDC test:      lazbuild cdc_test.lpi && ./cdc_test.exe")
    print("  GUI:           lazbuild vdbgui.lpi")
    print("  DLL test:      ppc386 vdbapitest.lpr && ./vdbapitest.exe")

if __name__ == '__main__':
    main()