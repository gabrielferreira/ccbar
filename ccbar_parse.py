#!/usr/bin/env python3
"""ccbar_parse.py — Centralized JSONL parser for ccbar.

Outputs JSON with all metrics for a session file and/or daily totals.

Usage:
    python3 ccbar_parse.py --session <file.jsonl>
    python3 ccbar_parse.py --daily <claude_projects_dir>
    python3 ccbar_parse.py --session <file.jsonl> --daily <claude_projects_dir>
"""

import json, sys, os, argparse
from datetime import datetime, timezone
from collections import Counter


def parse_session(filepath):
    """Parse a single session JSONL file and return all metrics."""
    tin = tout = tcw = tcr = 0
    turns_user = 0
    turns_assistant = 0
    tool_calls = Counter()
    tool_errors = 0
    models = Counter()
    timestamps = []
    stop_reasons = Counter()
    web_searches = 0
    web_fetches = 0

    try:
        with open(filepath) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                ts = obj.get("timestamp")
                if ts:
                    try:
                        timestamps.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                    except Exception:
                        pass

                msg_type = obj.get("type", "")
                msg = obj.get("message", {})
                if not isinstance(msg, dict):
                    continue

                role = msg.get("role", "")

                if msg_type == "user" or role == "user":
                    content = msg.get("content", [])
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                if block.get("type") == "tool_result":
                                    if block.get("is_error"):
                                        tool_errors += 1
                    # Only count actual user messages (not tool results)
                    if isinstance(content, str) or (
                        isinstance(content, list) and any(
                            isinstance(b, dict) and b.get("type") == "text"
                            for b in content
                        )
                    ):
                        turns_user += 1

                if msg_type == "assistant" or role == "assistant":
                    turns_assistant += 1

                    model = msg.get("model", "")
                    if model:
                        models[model] += 1

                    stop = msg.get("stop_reason", "")
                    if stop:
                        stop_reasons[stop] += 1

                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        usage = obj.get("usage")
                    if isinstance(usage, dict):
                        tin += usage.get("input_tokens", 0)
                        tout += usage.get("output_tokens", 0)
                        tcw += usage.get("cache_creation_input_tokens", 0)
                        tcr += usage.get("cache_read_input_tokens", 0)
                        stu = usage.get("server_tool_use", {})
                        if isinstance(stu, dict):
                            web_searches += stu.get("web_search_requests", 0)
                            web_fetches += stu.get("web_fetch_requests", 0)

                    content = msg.get("content", [])
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "tool_use":
                                name = block.get("name", "unknown")
                                tool_calls[name] += 1
    except Exception:
        pass

    # Duration
    duration_sec = 0
    duration_fmt = "0m"
    if len(timestamps) >= 2:
        start, end = min(timestamps), max(timestamps)
        duration_sec = int((end - start).total_seconds())
        h, m = duration_sec // 3600, (duration_sec % 3600) // 60
        duration_fmt = f"{h}h{m:02d}m" if h > 0 else f"{m}m"

    ctx_total = tin + tcw + tcr
    total_input_raw = tin + tcw + tcr
    cache_hit_pct = round(tcr * 100 / total_input_raw, 1) if total_input_raw > 0 else 0
    cache_savings = round(tcr * (3.00 - 0.30) / 1_000_000, 4) if tcr > 0 else 0

    # Primary model
    primary_model = models.most_common(1)[0][0] if models else "unknown"

    return {
        "input_tokens": tin,
        "output_tokens": tout,
        "cache_write_tokens": tcw,
        "cache_read_tokens": tcr,
        "context_total": ctx_total,
        "turns_user": turns_user,
        "turns_assistant": turns_assistant,
        "tool_calls": dict(tool_calls.most_common()),
        "tool_calls_total": sum(tool_calls.values()),
        "tool_errors": tool_errors,
        "models": dict(models),
        "primary_model": primary_model,
        "stop_reasons": dict(stop_reasons),
        "duration_sec": duration_sec,
        "duration_fmt": duration_fmt,
        "cache_hit_pct": cache_hit_pct,
        "cache_savings_usd": cache_savings,
        "web_searches": web_searches,
        "web_fetches": web_fetches,
    }


def parse_daily(base_dir):
    """Parse all sessions modified today and return per-project breakdown."""
    today = datetime.now(timezone.utc).date()
    projects = {}
    total = {"input_tokens": 0, "output_tokens": 0, "cache_write_tokens": 0,
             "cache_read_tokens": 0, "sessions": 0, "tool_calls": 0}

    for root, dirs, files in os.walk(base_dir):
        dirs[:] = [d for d in dirs if d != "subagents"]
        for fname in files:
            if not fname.endswith(".jsonl"):
                continue
            fpath = os.path.join(root, fname)
            mtime = datetime.fromtimestamp(os.path.getmtime(fpath), tz=timezone.utc).date()
            if mtime != today:
                continue

            # Project name from directory
            rel = os.path.relpath(root, base_dir)
            project_key = rel.split("/")[0] if "/" in rel else rel

            session = parse_session(fpath)

            if project_key not in projects:
                projects[project_key] = {
                    "input_tokens": 0, "output_tokens": 0,
                    "cache_write_tokens": 0, "cache_read_tokens": 0,
                    "sessions": 0, "tool_calls": 0, "models": [],
                }

            p = projects[project_key]
            p["input_tokens"] += session["input_tokens"]
            p["output_tokens"] += session["output_tokens"]
            p["cache_write_tokens"] += session["cache_write_tokens"]
            p["cache_read_tokens"] += session["cache_read_tokens"]
            p["sessions"] += 1
            p["tool_calls"] += session["tool_calls_total"]
            if session["primary_model"] not in p["models"]:
                p["models"].append(session["primary_model"])

            total["input_tokens"] += session["input_tokens"]
            total["output_tokens"] += session["output_tokens"]
            total["cache_write_tokens"] += session["cache_write_tokens"]
            total["cache_read_tokens"] += session["cache_read_tokens"]
            total["sessions"] += 1
            total["tool_calls"] += session["tool_calls_total"]

    return {"projects": projects, "total": total}


def parse_window(base_dir, hours=5):
    """Estimate current plan window usage using block heuristic.

    Claude's plan limit resets every 5h, but the exact reset time isn't
    exposed locally. This uses the same approach as Claude-Code-Usage-Monitor:
    1. Collect all timestamped usage entries from recent files
    2. Sort by timestamp
    3. Walk backwards from now — detect the current "block" by finding
       where a gap >= `hours` hours occurs or where we hit the boundary
       of a window aligned to the nearest full hour
    4. Sum only tokens within the current block
    """
    from datetime import timedelta

    now = datetime.now(timezone.utc)
    scan_cutoff = now - timedelta(hours=hours * 2)  # scan wider to find block boundary
    scan_cutoff_ts = scan_cutoff.timestamp()

    # Collect all (timestamp, usage_dict) entries
    entries = []

    for root, dirs, files in os.walk(base_dir):
        dirs[:] = [d for d in dirs if d != "subagents"]
        for fname in files:
            if not fname.endswith(".jsonl"):
                continue
            fpath = os.path.join(root, fname)
            if os.path.getmtime(fpath) < scan_cutoff_ts:
                continue

            try:
                with open(fpath) as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            obj = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        ts = obj.get("timestamp")
                        if not ts:
                            continue
                        try:
                            msg_time = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        except Exception:
                            continue
                        if msg_time < scan_cutoff:
                            continue

                        msg = obj.get("message", {})
                        if not isinstance(msg, dict):
                            continue
                        if msg.get("role") != "assistant":
                            continue

                        usage = msg.get("usage")
                        if not isinstance(usage, dict):
                            usage = obj.get("usage")
                        if not isinstance(usage, dict):
                            continue

                        tools = 0
                        content = msg.get("content", [])
                        if isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict) and block.get("type") == "tool_use":
                                    tools += 1

                        entries.append((msg_time, usage, tools))
            except Exception:
                pass

    if not entries:
        return {"input_tokens": 0, "output_tokens": 0, "cache_write_tokens": 0,
                "cache_read_tokens": 0, "sessions": 0, "tool_calls": 0,
                "window_start": None, "window_end": None}

    entries.sort(key=lambda x: x[0])

    # Check for manual reset file (line 1: timestamp, line 2: base %)
    # Derive claude home from base_dir (which is <claude_home>/projects)
    claude_home = os.path.dirname(base_dir.rstrip("/"))
    reset_file = os.path.join(claude_home, "ccbar_reset")
    manual_reset = None
    base_pct = 0
    if os.path.exists(reset_file):
        try:
            with open(reset_file) as f:
                lines = f.read().strip().split("\n")
                manual_reset = datetime.fromisoformat(lines[0].strip())
                if len(lines) > 1:
                    base_pct = int(lines[1].strip())
        except Exception:
            pass

    # Find current block: walk backwards from the most recent entry.
    # A new block starts when there's a gap >= `hours` hours between entries.
    block_start_idx = 0
    for i in range(len(entries) - 1, 0, -1):
        gap = (entries[i][0] - entries[i - 1][0]).total_seconds() / 3600
        if gap >= hours:
            block_start_idx = i
            break

    # Round block start to nearest full hour (UTC)
    first_ts = entries[block_start_idx][0]
    window_start = first_ts.replace(minute=0, second=0, microsecond=0)
    window_end = window_start + timedelta(hours=hours)

    # If we're past the window end, advance to the current window.
    # This handles the case where the user worked continuously across
    # window boundaries without a gap.
    while window_end <= now:
        window_start = window_end
        window_end = window_start + timedelta(hours=hours)

    # Manual reset overrides if it falls within the current window period
    if manual_reset and manual_reset > window_start:
        window_start = manual_reset
        window_end = window_start + timedelta(hours=hours)

    # Sum tokens within the current window
    total = {"input_tokens": 0, "output_tokens": 0, "cache_write_tokens": 0,
             "cache_read_tokens": 0, "sessions": 0, "tool_calls": 0,
             "window_start": window_start.isoformat(),
             "window_end": window_end.isoformat()}

    count = 0
    for msg_time, usage, tools in entries:
        if msg_time < window_start:
            continue
        total["input_tokens"] += usage.get("input_tokens", 0)
        total["output_tokens"] += usage.get("output_tokens", 0)
        total["cache_write_tokens"] += usage.get("cache_creation_input_tokens", 0)
        total["cache_read_tokens"] += usage.get("cache_read_input_tokens", 0)
        total["tool_calls"] += tools
        count += 1

    total["sessions"] = count
    # Only carry base_pct if the manual reset belongs to the current window
    total["base_pct"] = base_pct if (manual_reset and manual_reset > window_start) else 0

    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", help="Path to a .jsonl session file")
    parser.add_argument("--daily", help="Path to claude projects directory")
    parser.add_argument("--window", help="Path to claude projects directory (for 5h rolling window)")
    args = parser.parse_args()

    result = {}

    if args.session:
        result["session"] = parse_session(args.session)

    if args.daily:
        result["daily"] = parse_daily(args.daily)

    if args.window:
        result["window"] = parse_window(args.window)

    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
