#!/usr/bin/env python3
"""
Dynamo Lab - Load Generator for Planner Exercise
Sends concurrent inference requests to the Dynamo frontend to drive
TTFT/ITL metrics and trigger Planner scaling decisions.

Usage:
  python3 load-gen.py                     # low load (2 req/s)
  python3 load-gen.py --rps 10            # high load (10 req/s)
  python3 load-gen.py --rps 0             # stop load (sends 0)
  python3 load-gen.py --duration 120      # run for 2 minutes
"""

import argparse
import asyncio
import time
import sys

import aiohttp

FRONTEND_URL = "http://10.110.107.86:8000"
MODEL = "nvidia/Llama-3.1-8B-Instruct-FP8"

# Prompts of varying lengths to simulate real workloads
PROMPTS = [
    ("short", "What is Kubernetes?", 50),
    ("medium", "Explain how a transformer neural network processes text tokens during inference, focusing on the attention mechanism.", 100),
    ("long", "You are an AI assistant helping a developer debug a distributed systems issue. The developer reports that their microservices architecture is experiencing intermittent latency spikes under load. Describe in detail the possible root causes and a systematic debugging approach.", 200),
]

async def send_request(session: aiohttp.ClientSession, prompt: str, max_tokens: int, idx: int) -> dict:
    payload = {
        "model": MODEL,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": False,
    }
    t0 = time.monotonic()
    try:
        async with session.post(
            f"{FRONTEND_URL}/v1/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=60),
        ) as resp:
            data = await resp.json()
            elapsed = (time.monotonic() - t0) * 1000
            timing = data.get("nvext", {}).get("timing", {})
            ttft = timing.get("total_time_ms", elapsed)
            tokens = data.get("usage", {}).get("completion_tokens", 0)
            print(f"  req#{idx:04d}  ttft={ttft:.0f}ms  tokens={tokens}", flush=True)
            return {"ok": True, "ttft": ttft}
    except Exception as e:
        elapsed = (time.monotonic() - t0) * 1000
        print(f"  req#{idx:04d}  ERROR after {elapsed:.0f}ms: {e}", flush=True)
        return {"ok": False}


async def run_load(rps: float, duration: int):
    if rps == 0:
        print("Load set to 0 req/s — sending nothing. Planner will see idle traffic.")
        return

    interval = 1.0 / rps
    end_time = time.monotonic() + duration
    req_idx = 0
    ok_count = 0
    err_count = 0
    prompt_idx = 0

    connector = aiohttp.TCPConnector(limit=50)
    async with aiohttp.ClientSession(connector=connector) as session:
        print(f"Sending ~{rps:.1f} req/s for {duration}s to {FRONTEND_URL}")
        print(f"Model: {MODEL}")
        print("-" * 60)
        tasks = []
        while time.monotonic() < end_time:
            label, prompt, max_tokens = PROMPTS[prompt_idx % len(PROMPTS)]
            prompt_idx += 1
            req_idx += 1
            task = asyncio.create_task(
                send_request(session, prompt, max_tokens, req_idx)
            )
            tasks.append(task)
            await asyncio.sleep(interval)

        results = await asyncio.gather(*tasks, return_exceptions=True)
        for r in results:
            if isinstance(r, dict) and r.get("ok"):
                ok_count += 1
            else:
                err_count += 1

    print("-" * 60)
    print(f"Done: {ok_count} succeeded, {err_count} failed ({req_idx} total)")


def main():
    parser = argparse.ArgumentParser(description="Dynamo load generator")
    parser.add_argument("--rps", type=float, default=2.0,
                        help="Requests per second (default: 2.0)")
    parser.add_argument("--duration", type=int, default=90,
                        help="Duration in seconds (default: 90)")
    args = parser.parse_args()

    print(f"\n{'='*60}")
    print(f"  Dynamo Load Generator")
    print(f"  RPS: {args.rps}  |  Duration: {args.duration}s")
    print(f"{'='*60}\n")

    asyncio.run(run_load(args.rps, args.duration))


if __name__ == "__main__":
    main()
