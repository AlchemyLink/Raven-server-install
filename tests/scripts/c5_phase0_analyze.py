#!/usr/bin/env python3
"""
C5 Phase 0 — Results Analyzer

Parses a phase0_results_*.txt file and prints a categorized table:
  OK       — http 2xx/3xx, connect <2s
  SLOW     — http 2xx/3xx, connect >=2s (latency concern)
  BLOCKED  — http 4xx/5xx or code 000 (no response)

Usage:
    python3 tests/scripts/c5_phase0_analyze.py tests/phase0_results_*.txt
"""

import sys
import re

CONNECT_SLOW_THRESHOLD = 2.0  # seconds — above this = latency concern

def parse_file(path: str) -> "list[dict]":
    results = []
    in_domain_section = False
    with open(path) as f:
        for line in f:
            line = line.strip()
            if ".ru Domain Reachability" in line:
                in_domain_section = True
                continue
            if in_domain_section and line.startswith("=== Decision"):
                break
            if not in_domain_section or not line or line.startswith("Format:") or line.startswith("("):
                continue
            # Format: domain | dns_s | connect_s | total_s | http_code
            parts = line.split("|")
            if len(parts) != 5:
                continue
            domain, dns, connect, total, code = [p.strip() for p in parts]
            try:
                connect_f = float(connect)
            except ValueError:
                connect_f = -1.0
            try:
                total_f = float(total)
            except ValueError:
                total_f = -1.0
            try:
                code_i = int(code)
            except ValueError:
                code_i = 0
            results.append({
                "domain": domain,
                "dns": dns,
                "connect": connect,
                "connect_f": connect_f,
                "total": total,
                "total_f": total_f,
                "code": code_i,
            })
    return results

def categorize(r: dict) -> str:
    if r["code"] == 0 or r["code"] >= 400:
        return "BLOCKED"
    if r["connect_f"] >= CONNECT_SLOW_THRESHOLD:
        return "SLOW"
    return "OK"

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    for path in sys.argv[1:]:
        print(f"\n{'='*70}")
        print(f"File: {path}")
        print(f"{'='*70}")

        results = parse_file(path)
        if not results:
            print("No domain results found — check file format.")
            continue

        by_cat: dict[str, list] = {"OK": [], "SLOW": [], "BLOCKED": []}
        for r in results:
            cat = categorize(r)
            by_cat[cat].append(r)

        # Print summary table
        header = f"{'Domain':<30} {'Connect':>8} {'Total':>8} {'Code':>6}  Status"
        print(header)
        print("-" * len(header))

        for cat in ("BLOCKED", "SLOW", "OK"):
            for r in sorted(by_cat[cat], key=lambda x: x["connect_f"]):
                flag = {"OK": "✓", "SLOW": "~", "BLOCKED": "✗"}[cat]
                print(
                    f"{r['domain']:<30} {r['connect']:>8} {r['total']:>8} {r['code']:>6}  {flag} {cat}"
                )

        print()
        total = len(results)
        blocked_domains = [r["domain"] for r in by_cat["BLOCKED"]]
        slow_domains = [r["domain"] for r in by_cat["SLOW"]]

        print(f"Summary: {len(by_cat['OK'])} OK / {len(by_cat['SLOW'])} SLOW / {len(by_cat['BLOCKED'])} BLOCKED / {total} total")
        print()

        if blocked_domains:
            print("BLOCKED — require RU-exit routing (Phase 6-7 candidates):")
            for d in blocked_domains:
                print(f"  - {d}")
        else:
            print("No domains blocked — EU-direct acceptable, Phase 6-7 tunnel NOT required.")

        if slow_domains:
            print()
            print(f"SLOW (connect >= {CONNECT_SLOW_THRESHOLD}s) — latency concern, monitor:")
            for d in slow_domains:
                r = next(x for x in by_cat["SLOW"] if x["domain"] == d)
                print(f"  - {d}  ({r['connect']}s connect)")

        print()
        if not blocked_domains and not slow_domains:
            print("DECISION GATE: Phase 6-7 (VLESS tunnel) NOT needed. Proceed with Phase 1-5.")
        elif blocked_domains:
            print("DECISION GATE: Phase 6-7 NEEDED for blocked domains listed above.")
        else:
            print("DECISION GATE: Borderline — review SLOW domains with real user testing.")

if __name__ == "__main__":
    main()
