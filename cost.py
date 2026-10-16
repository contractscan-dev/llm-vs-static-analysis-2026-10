import json, glob, collections
# DeepSeek pricing page (fetched 2026-10-16): deepseek-flash, per 1M tokens; peak = 2x off-peak. Upper bound uses PEAK.
P = {"hit": 0.006, "miss": 0.30, "out": 1.20}
T = collections.defaultdict(lambda: collections.Counter())
for f in glob.glob("raw/*/*.json"):
    j = json.load(open(f)); u = j["response"].get("usage") or {}; m = j["model_requested"]
    T[m]["calls"] += 1; T[m]["hit"] += u.get("prompt_cache_hit_tokens", 0); T[m]["miss"] += u.get("prompt_cache_miss_tokens", u.get("prompt_tokens", 0) - u.get("prompt_cache_hit_tokens", 0))
    T[m]["out"] += u.get("completion_tokens", 0); T[m]["reason"] += (u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
tot = 0
for m, c in T.items():
    usd = sum(c[k] * P[k] / 1e6 for k in P); tot += usd; print(m, dict(c), f"peak-rate cost ${usd:.3f}")
print(f"TOTAL upper bound ${tot:.3f} (~CNY {tot*7.1:.2f})")
