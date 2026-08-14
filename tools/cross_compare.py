#!/usr/bin/env python3
"""Merge per-machine `corpus/results/*.json` into a cross-OS/cross-chip table.

Each result file was produced by tools/cross_bench.sh and is tagged in its
filename as <engine>_<mode>_<machine>.json. This script prints one row per
(machine, engine, mode) and writes a comparison.md into the results dir.

Usage:
  python3 tools/cross_compare.py [--results DIR] [--md PATH]
"""
import argparse
import glob
import json
import os
import re

def parse_tag(fname):
    # <engine>_<mode>_<machine>.json
    stem = fname[: -len(".json")]
    parts = stem.split("_")
    engine, mode = parts[0], parts[1]
    machine = "_".join(parts[2:])
    return engine, mode, machine

def load(path):
    with open(path) as f:
        return json.load(f)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="corpus/results")
    ap.add_argument("--md", default=None)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.results, "*.json")))
    if not files:
        print(f"no result files in {args.results} — run tools/cross_bench.sh on each machine first")
        return

    rows = []
    for path in files:
        engine, mode, machine = parse_tag(os.path.basename(path))
        d = load(path)
        # Adaptive reports accuracy/latency under `adaptive`; other modes at top level.
        if mode == "adaptive":
            ad = d.get("adaptive", {})
            acc = ad.get("accuracy", {})
            p95 = ad.get("p95_latency_ms")
        else:
            acc = d.get("accuracy", {})
            p95 = d.get("summary", {}).get("p95_latency_ms")
        env = d.get("environment", {})
        rows.append({
            "machine": machine,
            "engine": engine,
            "mode": mode,
            "os": env.get("os", "?"),
            "device": env.get("device_model", "?"),
            "soc": env.get("soc", "?"),
            "corpus_version": d.get("corpus_version", "?"),
            "engine_api": (d.get("ocr", {}) or {}).get("engine_api", "?"),
            "engine_revision": (d.get("ocr", {}) or {}).get("engine_revision", "?"),
            "cer": acc.get("cer_macro", float("nan")),
            "wer": acc.get("wer_macro", float("nan")),
            "exact": acc.get("exact_match", float("nan")),
            "p95_ms": (p95 or float("nan")),
        })

    rows.sort(key=lambda r: (r["machine"], r["engine"], r["mode"]))

    lines = []
    hdr = f"{'machine':<28} {'eng':<7} {'mode':<11} {'cer':>7} {'wer':>7} {'exact%':>7} {'p95ms':>8}   os / device"
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for r in rows:
        lines.append(
            f"{r['machine']:<28} {r['engine']:<7} {r['mode']:<11} "
            f"{r['cer']:>7.3f} {r['wer']:>7.3f} {r['exact'] * 100:>6.1f}% {r['p95_ms']:>8.0f}   "
            f"{r['os']} / {r['device']}"
        )

    out = "\n".join(lines)
    print(out)

    md = args.md or os.path.join(args.results, "comparison.md")
    with open(md, "w") as f:
        f.write("| machine | engine | mode | CER | WER | exact% | p95 ms | OS / device |\n")
        f.write("|---|---|---|---|---|---|---|---|\n")
        for r in rows:
            f.write(
                f"| {r['machine']} | {r['engine']} | {r['mode']} | {r['cer']:.3f} | "
                f"{r['wer']:.3f} | {r['exact'] * 100:.1f}% | {r['p95_ms']:.0f} | "
                f"{r['os']} / {r['device']} |\n"
            )
    print(f"\n📄 comparison written to: {md}")

if __name__ == "__main__":
    main()
