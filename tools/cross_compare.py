#!/usr/bin/env python3
"""Merge per-machine `corpus/results/*.json` into a cross-OS/cross-chip table.

Each result file was produced by tools/cross_bench.sh and is tagged in its
filename as <engine>_<mode>_<machine>.json. This script prints:

  1. One row per (machine, engine, mode): CER/WER/exact (normalized + strict),
     p95 latency, throughput.
  2. A per-category CER matrix (rows = corpus layout category, columns =
     machine) so it's obvious where Vision breaks, derived from the
     legacy/accurate result of each machine.

Usage:
  python3 tools/cross_compare.py [--results DIR] [--md PATH] [--corpus DIR]
"""
import argparse
import glob
import json
import math
import os

def parse_tag(fname):
    stem = fname[: -len(".json")]
    parts = stem.split("_")
    return parts[0], parts[1], "_".join(parts[2:])

def load(path):
    with open(path) as f:
        return json.load(f)

def layout_by_id(corpus_dir):
    """manifest.json files[].filename -> layout category."""
    manifest = os.path.join(corpus_dir, "manifest.json")
    if not os.path.exists(manifest):
        return {}
    with open(manifest) as f:
        m = json.load(f)
    return {f["filename"]: f.get("layout", "other") for f in m.get("files", [])}

def category_of(filename, layout_by_id):
    # "foo.pdf (page 1)" / "foo.png" -> manifest id (strip page suffix)
    key = filename.split(" (page")[0]
    return layout_by_id.get(key, "other")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="corpus/results")
    ap.add_argument("--md", default=None)
    ap.add_argument("--corpus", default="corpus")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.results, "*.json")))
    if not files:
        print(f"no result files in {args.results} — run tools/cross_bench.sh on each machine first")
        return

    layout_map = layout_by_id(args.corpus)

    rows = []
    for path in files:
        engine, mode, machine = parse_tag(os.path.basename(path))
        d = load(path)
        if mode == "adaptive":
            ad = d.get("adaptive", {})
            acc = ad.get("accuracy", {})
            p95 = ad.get("p95_latency_ms")
            img_s = ad.get("throughput_items_s")
        else:
            acc = d.get("accuracy", {})
            p95 = d.get("summary", {}).get("p95_latency_ms")
            img_s = d.get("summary", {}).get("images_per_second")
        env = d.get("environment", {})
        rows.append({
            "machine": machine, "engine": engine, "mode": mode,
            "os": env.get("os", "?"), "device": env.get("device_model", "?"),
            "soc": env.get("soc", "?"),
            "corpus_version": d.get("corpus_version", "?"),
            "engine_api": (d.get("ocr", {}) or {}).get("engine_api", "?"),
            "engine_revision": (d.get("ocr", {}) or {}).get("engine_revision", "?"),
            "cer": acc.get("cer_macro", math.nan),
            "cer_strict": acc.get("cer_macro_strict", math.nan),
            "wer": acc.get("wer_macro", math.nan),
            "exact": acc.get("exact_match", math.nan),
            "p95_ms": (p95 or math.nan),
            "img_s": (img_s or math.nan),
            "per_file": acc.get("per_file", []),
        })

    rows.sort(key=lambda r: (r["machine"], r["engine"], r["mode"]))

    lines = []
    hdr = (f"{'machine':<26} {'eng':<7} {'mode':<11} {'CER':>6} {'CERs':>6} "
           f"{'WER':>6} {'exact%':>7} {'p95ms':>7} {'img/s':>7}")
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for r in rows:
        lines.append(
            f"{r['machine']:<26} {r['engine']:<7} {r['mode']:<11} "
            f"{r['cer']:>6.3f} {r['cer_strict']:>6.3f} {r['wer']:>6.3f} "
            f"{r['exact'] * 100:>6.1f}% {r['p95_ms']:>7.0f} {r['img_s']:>7.1f}"
        )
    print("\n".join(lines))
    print("\nCER legend: normalized macro (CER) and strict/unnormalized (CERs).")

    # Per-category CER matrix using each machine's legacy/accurate result.
    acc_rows = [r for r in rows if r["engine"] == "legacy" and r["mode"] == "accurate"]
    if acc_rows and layout_map:
        cats = []
        for f in sorted(layout_map):
            c = layout_map[f]
            if c not in cats:
                cats.append(c)
        lines = []
        hdr = f"{'category':<12}" + "".join(f"{m['machine'][:18]:>19}" for m in acc_rows)
        lines.append(hdr)
        lines.append("-" * len(hdr))
        for cat in cats:
            row = f"{cat:<12}"
            for m in acc_rows:
                pf = [p for p in m["per_file"] if category_of(p.get("filename", ""), layout_map) == cat]
                cer = (sum(p["cer"] for p in pf) / len(pf)) if pf else math.nan
                row += f"{cer:>19.3f}"
            lines.append(row)
        print("\nPer-category normalized CER (legacy/accurate):")
        print("\n".join(lines))

    out = "\n".join(lines)
    md = args.md or os.path.join(args.results, "comparison.md")
    with open(md, "w") as f:
        f.write("| machine | engine | mode | CER | CER strict | WER | exact% | p95 ms | img/s |\n")
        f.write("|---|---|---|---|---|---|---|---|---|\n")
        for r in rows:
            f.write(
                f"| {r['machine']} | {r['engine']} | {r['mode']} | {r['cer']:.3f} | "
                f"{r['cer_strict']:.3f} | {r['wer']:.3f} | {r['exact'] * 100:.1f}% | "
                f"{r['p95_ms']:.0f} | {r['img_s']:.1f} |\n"
            )
    print(f"\n📄 comparison written to: {md}")

if __name__ == "__main__":
    main()
