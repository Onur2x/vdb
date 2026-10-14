#!/usr/bin/env python3
"""
VDB Engine Skill - Next Task Recommender
Shows the next logical roadmap item to work on based on current status.
"""

import os
import re

PROJECT_ROOT = r'D:\veritabani'

def parse_roadmap():
    """Parse yol_haritasi.md for roadmap items"""
    roadmap_path = os.path.join(PROJECT_ROOT, 'yol_haritasi.md')
    if not os.path.exists(roadmap_path):
        return []
    
    with open(roadmap_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    items = []
    in_faz = None
    in_table = False
    
    for line in content.split('\n'):
        # Detect phase headers
        if line.startswith('### ') and 'FAZ' in line:
            in_faz = line.strip('# ').strip()
            in_table = False
            continue
        
        # Detect table start
        if '├──────┼' in line and 'Özellik' in line:
            in_table = True
            continue
        
        # Detect table end
        if in_table and '└──────┴' in line:
            in_table = False
            continue
        
        # Parse table rows
        if in_table and '│' in line:
            parts = [p.strip() for p in line.split('│')]
            if len(parts) >= 5:
                id_ = parts[1]
                feature = parts[2]
                desc = parts[3]
                difficulty = parts[4]
                
                # Check if done
                done = '✅ BITTI' in line or 'BITTI' in line
                
                items.append({
                    'faz': in_faz,
                    'id': id_,
                    'feature': feature,
                    'desc': desc,
                    'difficulty': difficulty,
                    'done': done
                })
    
    return items

def main():
    items = parse_roadmap()
    
    print("[ROADMAP] VDB Roadmap - Next Tasks")
    print("=" * 60)
    
    # Group by phase
    by_faz = {}
    for item in items:
        faz = item['faz'] or 'Unknown'
        if faz not in by_faz:
            by_faz[faz] = []
        by_faz[faz].append(item)
    
    # Show next undone item per phase
    for faz_name in ['[CRITICAL] FAZ 0: Temel Veri Butunlugu ve Eszamanlilik',
                     '[HIGH] FAZ 1: SQL Standartlari ve Gelismis Iliskisel Ozellikler',
                     '[MEDIUM] FAZ 2: Olceklenebilirlik ve Performans',
                     '[LOW] FAZ 3: Platform, Guvenlik ve Ekosistem']:
        if faz_name not in by_faz:
            continue
        
        print(f"\n{faz_name}")
        print("-" * 60)
        
        undone = [i for i in by_faz[faz_name] if not i['done']]
        done = [i for i in by_faz[faz_name] if i['done']]
        
        if undone:
            next_item = undone[0]
            print(f"  [NEXT] {next_item['id']} - {next_item['feature']}")
            print(f"      {next_item['desc'][:80]}")
            print(f"      Difficulty: {next_item['difficulty']}")
            if len(undone) > 1:
                print(f"      ... +{len(undone)-1} more in this phase")
        elif done:
            print(f"  [DONE] All {len(done)} items complete")
        else:
            print(f"  (no items)")
    
    # Summary
    total = len(items)
    done_count = sum(1 for i in items if i['done'])
    print(f"\n[STATS] Overall: {done_count}/{total} complete ({done_count/total*100:.0f}%)")

if __name__ == '__main__':
    main()