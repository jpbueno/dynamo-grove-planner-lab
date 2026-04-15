#!/usr/bin/env python3
"""
Dynamo Lab - Load Generator for Planner Exercise
Sends concurrent inference requests to the Dynamo frontend to drive
TTFT/ITL metrics and trigger Planner scaling decisions.

Usage:
  python3 load-gen.py --url http://<frontend-ip>:8000          # required: frontend URL
  python3 load-gen.py --url http://<frontend-ip>:8000 --rps 10 # high load
  python3 load-gen.py --url http://<frontend-ip>:8000 --rps 0  # stop load
  python3 load-gen.py --duration 120                            # run for 2 minutes

  # Discover the frontend URL automatically:
  FRONTEND_IP=$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}')
  python3 load-gen.py --url http://$FRONTEND_IP:8000
"""

import argparse
import asyncio
import subprocess
import time
import sys

import aiohttp

MODEL = "nvidia/Llama-3.1-8B-Instruct-FP8"

# Prompts of varying lengths to simulate real workloads
PROMPTS = [
    ("short", "What is Kubernetes?", 50),
    ("medium", "Explain how a transformer neural network processes text tokens during inference, focusing on the attention mechanism.", 100),
    ("long", "You are an AI assistant helping a developer debug a distributed systems issue. The developer reports that their microservices architecture is experiencing intermittent latency spikes under load. Describe in detail the possible root causes and a systematic debugging approach.", 200),
]

def discover_frontend_url() -> str:
    """Auto-discover the frontend ClusterIP via kubectl."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "svc", "dynamo-lab-frontend", "-n", "dynamo-lab",
             "-o", "jsonpath={.spec.clusterIP}"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            url = f"http://{result.stdout.strip()}:8000"
            print(f"  Auto-discovered frontend: {url}")
            return url
    except Exception:
        pass
    return ""


async def send_request(session: aiohttp.ClientSession, frontend_url: str,
                       prompt: str, max_tokens: int, idx: int) -> dict:
    payload = {
        "model": MODEL,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": False,
    }
    t0 = time.monotonic()
    try:
        async with session.post(
            f"{frontend_url}/v1/completions",
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


async def run_load(frontend_url: str, rps: float, duration: int):
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
        print(f"Sending ~{rps:.1f} req/s for {duration}s to {frontend_url}")
        print(f"Model: {MODEL}")
        print("-" * 60)
        tasks = []
        while time.monotonic() < end_time:
            label, prompt, max_tokens = PROMPTS[prompt_idx % len(PROMPTS)]
            prompt_idx += 1
            req_idx += 1
            task = asyncio.create_task(
                send_request(session, frontend_url, prompt, max_tokens, req_idx)
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
    parser.add_argument("--url", type=str, default="",
                        help="Frontend URL (e.g. http://10.96.0.100:8000). "
                             "If omitted, auto-discovers via kubectl.")
    parser.add_argument("--rps", type=float, default=2.0,
                        help="Requests per second (default: 2.0)")
    parser.add_argument("--duration", type=int, default=90,
                        help="Duration in seconds (default: 90)")
    args = parser.parse_args()

    frontend_url = args.url or discover_frontend_url()
    if not frontend_url:
        print("ERROR: Could not determine frontend URL.")
        print("Pass it explicitly:  python3 load-gen.py --url http://<frontend-ip>:8000")
        print("Or discover it:      kubectl get svc dynamo-lab-frontend -n dynamo-lab")
        sys.exit(1)

    print(f"\n{'='*60}")
    print(f"  Dynamo Load Generator")
    print(f"  Target: {frontend_url}")
    print(f"  RPS: {args.rps}  |  Duration: {args.duration}s")
    print(f"{'='*60}\n")

    asyncio.run(run_load(frontend_url, args.rps, args.duration))


if __name__ == "__main__":
    main()
