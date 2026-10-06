"""Evaluate a small hand-authored retrieval set, without running repository code.

The cases file is a JSON list of {"query", "path", "symbol"} objects for the indexed repository.
"""
import argparse
import json
import statistics
import time
from pathlib import Path

import httpx

parser = argparse.ArgumentParser()
parser.add_argument("--url", default="http://127.0.0.1:8765")
parser.add_argument("--cases", type=Path, required=True)
parser.add_argument("--output", type=Path, default=Path(".code-search/benchmark.json"))
parser.add_argument("--wait", action="store_true", help="Wait up to ten minutes for the first full index")
args = parser.parse_args()
cases = json.loads(args.cases.read_text())
rows = []
with httpx.Client(base_url=args.url, timeout=120, trust_env=False) as client:
    status = client.get("/status").json()
    deadline = time.monotonic() + 600
    while args.wait and status["phase"] not in {"ready", "error"} and time.monotonic() < deadline:
        time.sleep(2)
        status = client.get("/status").json()
    if status["phase"] != "ready":
        raise SystemExit(f"Wait for indexing to complete: {status['phase']}")
    for case in cases:
        for mode in ("semantic", "lexical", "hybrid"):
            start = time.perf_counter()
            response = client.post("/search", json={"query": case["query"], "mode": mode, "limit": 5, "max_chars": 24000})
            response.raise_for_status()
            result = response.json()
            hits = result["results"]
            rank = next((i for i, r in enumerate(hits, 1) if r["path"] == case["path"] and r["symbol"] == case["symbol"]), None)
            rows.append({**case, "mode": mode, "file_hit_at_5": any(r["path"] == case["path"] for r in hits),
                         "symbol_rank": rank, "elapsed_ms": result["elapsed_ms"],
                         "round_trip_ms": round((time.perf_counter() - start) * 1000, 2),
                         "results": [{k: r[k] for k in ("path", "symbol", "kind", "cosine", "lexical_rank")} for r in hits]})
    summary = {}
    for mode in ("semantic", "lexical", "hybrid"):
        subset = [r for r in rows if r["mode"] == mode]
        summary[mode] = {"file_hits_at_5": sum(r["file_hit_at_5"] for r in subset),
                         "symbol_hits_at_5": sum(r["symbol_rank"] is not None for r in subset),
                         "symbol_hits_at_1": sum(r["symbol_rank"] == 1 for r in subset),
                         "cases": len(subset), "median_elapsed_ms": round(statistics.median(r["elapsed_ms"] for r in subset), 2),
                         "max_elapsed_ms": max(r["elapsed_ms"] for r in subset)}
    report = {"measured_at": time.time(), "status": status, "summary": summary,
              "limitations": [f"{len(cases)} hand-authored questions; not a general code-search benchmark or an agent speedup measurement.",
                              "Lexical mode is SQLite FTS5 BM25, not ripgrep or an agent generating search patterns.",
                              "Semantic runs first and includes question embedding; hybrid reuses the query embedding cache.",
                              "Symbol hits require the exact expected symbol; related class/file hits count only as file hits."],
              "rows": rows}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(summary, indent=2))
