#!/usr/bin/env python3
"""
Scan Bitcoin Core block-fee history via getblockstats JSON-RPC and report
yearly fee-rate summaries (sat/vByte). Stdlib only — no pip install.

Usage:
    ./btc_fee_history.py scan   --conf <bitcoin.conf> [--csv block_fees.csv]
                                [--workers 8] [--batch 200]
                                [--start H] [--end H]
    ./btc_fee_history.py report [--csv block_fees.csv] [--today YYYY-MM-DD]

The CSV is resumable: rerun scan after the node catches up to extend it.
"""

import argparse
import csv
import json
import sys
import time
import urllib.request
from base64 import b64encode
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from statistics import median

CSV_HEADER = [
    "height", "time", "total_weight", "totalfee", "txs",
    "avgfeerate",
    "p10", "p25", "p50", "p75", "p90",
]

GETBLOCKSTATS_FIELDS = [
    "height", "time", "total_weight", "totalfee", "txs",
    "avgfeerate", "feerate_percentiles",
]


def parse_conf(path):
    cfg = {"rpcport": 8332}
    for raw in Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("[") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip()
    if "rpcuser" not in cfg or "rpcpassword" not in cfg:
        raise SystemExit(f"missing rpcuser/rpcpassword in {path}")
    cfg["rpcport"] = int(cfg.get("rpcport", 8332))
    cfg["rpchost"] = cfg.get("rpcbind", "localhost")
    return cfg


class RpcClient:
    def __init__(self, host, port, user, password):
        self.url = f"http://{host}:{port}/"
        token = b64encode(f"{user}:{password}".encode()).decode()
        self.auth = f"Basic {token}"

    def call(self, method, params):
        return self._post([{"jsonrpc": "1.0", "id": 0, "method": method, "params": params}])[0]

    def batch(self, calls):
        body = [
            {"jsonrpc": "1.0", "id": i, "method": m, "params": p}
            for i, (m, p) in enumerate(calls)
        ]
        responses = self._post(body)
        out = [None] * len(calls)
        for r in responses:
            out[r["id"]] = r
        return out

    def _post(self, body):
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            self.url, data=data,
            headers={"Authorization": self.auth, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=180) as resp:
            payload = json.loads(resp.read())
        if isinstance(payload, dict):
            payload = [payload]
        for r in payload:
            if r.get("error"):
                raise RuntimeError(f"RPC error: {r['error']}")
        return payload


def existing_max_height(csv_path):
    if not csv_path.exists() or csv_path.stat().st_size == 0:
        return -1
    last = -1
    with csv_path.open() as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            if not row:
                continue
            try:
                last = max(last, int(row[0]))
            except ValueError:
                continue
    return last


def fetch_chunk(rpc, heights):
    calls = [("getblockstats", [h, GETBLOCKSTATS_FIELDS]) for h in heights]
    responses = rpc.batch(calls)
    rows = []
    for resp in responses:
        s = resp["result"]
        pct = s.get("feerate_percentiles") or [0, 0, 0, 0, 0]
        rows.append([
            s["height"], s["time"], s["total_weight"], s["totalfee"], s["txs"],
            s["avgfeerate"],
            pct[0], pct[1], pct[2], pct[3], pct[4],
        ])
    return rows


def scan(args):
    cfg = parse_conf(args.conf)
    rpc = RpcClient(cfg["rpchost"], cfg["rpcport"], cfg["rpcuser"], cfg["rpcpassword"])
    info = rpc.call("getblockchaininfo", [])["result"]
    if info.get("initialblockdownload"):
        print(f"warning: node still in IBD (progress={info.get('verificationprogress'):.4f})",
              file=sys.stderr)
    tip = info["blocks"]
    print(f"tip height: {tip:,}", file=sys.stderr)

    csv_path = Path(args.csv)
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    start = args.start if args.start is not None else existing_max_height(csv_path) + 1
    end = args.end if args.end is not None else tip
    end = min(end, tip)
    if start > end:
        print(f"already up to date (last={start-1}, tip={tip})", file=sys.stderr)
        return
    total = end - start + 1
    print(f"scanning {start:,}..{end:,} ({total:,} blocks, "
          f"workers={args.workers}, batch={args.batch})", file=sys.stderr)

    new_file = not csv_path.exists() or csv_path.stat().st_size == 0
    f = csv_path.open("a", newline="")
    writer = csv.writer(f)
    if new_file:
        writer.writerow(CSV_HEADER)

    chunks = [list(range(h, min(h + args.batch, end + 1)))
              for h in range(start, end + 1, args.batch)]

    done = 0
    t0 = time.monotonic()
    try:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            # pool.map preserves submission order — CSV stays in height order,
            # so a crash leaves a contiguous prefix that resumes cleanly.
            for rows in pool.map(lambda c: fetch_chunk(rpc, c), chunks):
                writer.writerows(rows)
                done += len(rows)
                if done % (args.batch * 10) == 0 or done == total:
                    f.flush()
                    elapsed = time.monotonic() - t0
                    rate = done / elapsed if elapsed else 0
                    remaining = total - done
                    eta_min = (remaining / rate / 60) if rate else 0
                    print(f"  +{done:>9,}/{total:,}  "
                          f"@ {rate:6.0f} blk/s  eta {eta_min:5.1f} min",
                          file=sys.stderr)
    finally:
        f.flush()
        f.close()
    print(f"done. wrote {done:,} rows to {csv_path}", file=sys.stderr)


def report(args):
    csv_path = Path(args.csv)
    if not csv_path.exists():
        raise SystemExit(f"{csv_path} not found — run `scan` first")

    if args.today:
        today = datetime.fromisoformat(args.today).replace(tzinfo=timezone.utc)
    else:
        today = datetime.now(timezone.utc)
    today_ts = int(today.timestamp())

    by_year = {}
    rolling = []
    skipped_empty = 0
    with csv_path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            if int(row["txs"]) <= 1:
                skipped_empty += 1
                continue
            year = datetime.fromtimestamp(int(row["time"]), tz=timezone.utc).year
            by_year.setdefault(year, []).append(row)
            rolling.append(row)

    def vbyte_weighted_mean(rows, field):
        num = den = 0.0
        for r in rows:
            w = float(r["total_weight"]) / 4.0
            num += float(r[field]) * w
            den += w
        return num / den if den else 0.0

    def summary(rows):
        if not rows:
            return None
        return {
            "blocks": len(rows),
            "p10":    median(float(r["p10"]) for r in rows),
            "p25":    median(float(r["p25"]) for r in rows),
            "p50":    median(float(r["p50"]) for r in rows),
            "p75":    median(float(r["p75"]) for r in rows),
            "p90":    median(float(r["p90"]) for r in rows),
            "wmean":  vbyte_weighted_mean(rows, "avgfeerate"),
            "txs":    sum(int(r["txs"]) for r in rows),
        }

    windows = [("last 2y", 2), ("last 5y", 5), ("overall", None)]
    year_rows = []
    for year in sorted(by_year):
        s = summary(by_year[year])
        year_rows.append((str(year), s))
    window_rows = []
    for label, years in windows:
        if years is None:
            rows = rolling
        else:
            cutoff = today_ts - years * 365 * 86400
            rows = [r for r in rolling if int(r["time"]) >= cutoff]
        window_rows.append((label, summary(rows)))

    out = sys.stdout if args.out is None else open(args.out, "w")
    try:
        if args.format == "csv":
            w = csv.writer(out)
            w.writerow(["scope", "label", "blocks", "txs",
                        "p10", "p25", "p50", "p75", "p90", "vbyte_wmean"])
            for label, s in year_rows:
                w.writerow(["year", label, s["blocks"], s["txs"],
                            s["p10"], s["p25"], s["p50"], s["p75"], s["p90"],
                            f"{s['wmean']:.4f}"])
            for label, s in window_rows:
                if s is None:
                    continue
                w.writerow(["window", label, s["blocks"], s["txs"],
                            s["p10"], s["p25"], s["p50"], s["p75"], s["p90"],
                            f"{s['wmean']:.4f}"])
        else:
            print(file=out)
            print("# Bitcoin fee-rate history (sat/vByte)", file=out)
            print(file=out)
            print(f"Source: `getblockstats` per block. Empty blocks (txs<=1) "
                  f"excluded ({skipped_empty:,} blocks).", file=out)
            print(file=out)
            print("Columns: median across blocks of each per-block percentile "
                  "feerate (percentiles are vbyte-weighted within a block). "
                  "vByte-wmean is vbyte-weighted mean of `avgfeerate` "
                  "(skewed by spikes — context only).", file=out)
            print(file=out)
            print("## Per calendar year", file=out)
            print(file=out)
            print("| Year | Blocks  |   Txs (M) |  p10  |  p25  |  p50  |  p75  |  p90  | vByte-wmean |", file=out)
            print("|------|---------|-----------|-------|-------|-------|-------|-------|-------------|", file=out)
            for label, s in year_rows:
                print(f"| {label} | {s['blocks']:>7,} | {s['txs']/1e6:>9.2f} | "
                      f"{s['p10']:>5.2f} | {s['p25']:>5.2f} | {s['p50']:>5.2f} | "
                      f"{s['p75']:>5.2f} | {s['p90']:>5.2f} | {s['wmean']:>11.2f} |", file=out)
            print(file=out)
            print(f"## Trailing windows ending {today.date()}", file=out)
            print(file=out)
            print("| Window  | Blocks  |   Txs (M) |  p10  |  p25  |  p50  |  p75  |  p90  | vByte-wmean |", file=out)
            print("|---------|---------|-----------|-------|-------|-------|-------|-------|-------------|", file=out)
            for label, s in window_rows:
                if s is None:
                    print(f"| {label:<7} | — no data — |", file=out)
                    continue
                print(f"| {label:<7} | {s['blocks']:>7,} | {s['txs']/1e6:>9.2f} | "
                      f"{s['p10']:>5.2f} | {s['p25']:>5.2f} | {s['p50']:>5.2f} | "
                      f"{s['p75']:>5.2f} | {s['p90']:>5.2f} | {s['wmean']:>11.2f} |", file=out)
            print(file=out)
    finally:
        if out is not sys.stdout:
            out.close()


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="fetch block-fee stats into CSV (resumable)")
    s.add_argument("--conf", required=True, help="bitcoin.conf with rpcuser/rpcpassword")
    s.add_argument("--csv", default="block_fees.csv")
    s.add_argument("--workers", type=int, default=8)
    s.add_argument("--batch", type=int, default=200, help="heights per JSON-RPC batch")
    s.add_argument("--start", type=int, default=None, help="override start height")
    s.add_argument("--end", type=int, default=None, help="override end height (default: tip)")
    s.set_defaults(func=scan)

    r = sub.add_parser("report", help="print yearly + trailing-window summary")
    r.add_argument("--csv", default="block_fees.csv")
    r.add_argument("--today", default=None, help="YYYY-MM-DD (default: now)")
    r.add_argument("--format", choices=["md", "csv"], default="md")
    r.add_argument("--out", default=None, help="output file (default: stdout)")
    r.set_defaults(func=report)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
