"""Cross-model comparison (all models, same rubric). Reads scored.json + raw usage. Writes compare.json / compare.md."""
import json, glob, collections, statistics as st
from metrics import CONF, HOLD, AIK, cs
R = json.load(open("scored.json"))
DS_PRICE = {"hit": 0.006, "miss": 0.30, "out": 1.20}  # DeepSeek peak per 1M (upper bound)
cost = collections.defaultdict(list)
for f in glob.glob("raw/*/*.json"):
    j = json.load(open(f)); u = j["response"].get("usage") or {}
    if not u: continue
    if "cost" in u: c = u["cost"]
    else:
        hit = u.get("prompt_cache_hit_tokens", 0); c = (hit * DS_PRICE["hit"] + (u.get("prompt_tokens", 0) - hit) * DS_PRICE["miss"] + u.get("completion_tokens", 0) * DS_PRICE["out"]) / 1e6
    cost[j["model_requested"]].append((c, u.get("prompt_tokens", 0), u.get("completion_tokens", 0)))
CS_HOLD_HIT = {"holdout_MFT"}  # ContractScan's single holdout root-cause catch (summary.md)
SAFE = sorted({r["contract"] for r in R if r["contract"].startswith("safe_")})
out = {}
for m in sorted({r["model"] for r in R}):
    rs = [r for r in R if r["model"] == m]; main = [r for r in rs if not r["contract"].startswith("steer_")]
    by = collections.defaultdict(dict)
    for r in main: by[r["contract"]][r["run"]] = r
    o = {"answers": len(rs), "runs_per_contract": dict(collections.Counter(len(v) for v in by.values()))}
    h1 = [by[c][min(by[c])] for c in HOLD if c in by]
    o["holdout_rc_first_run"] = f"{sum(r['rc_hit'] for r in h1)}/{len(h1)}"
    ha = [r for c in HOLD for r in by.get(c, {}).values()]
    o["holdout_rc_per_answer"] = f"{sum(r['rc_hit'] for r in ha)}/{len(ha)}"
    o["holdout_contracts_any_run"] = sum(any(r["rc_hit"] for r in by.get(c, {}).values()) for c in HOLD)
    d1 = [by[c][min(by[c])] for c in CONF + AIK if c in by]
    o["design13+aiknown5_rc_first_run"] = f"{sum(r['rc_hit'] for r in d1)}/{len(d1)}" if d1 else "not run"
    sa = [r for c in SAFE for r in by.get(c, {}).values()]
    o["safe_false_do_not_deploy"] = f"{sum(r['verdict'] == 'do_not_deploy' for r in sa)}/{len(sa)} answers ({sum(any(r['verdict'] == 'do_not_deploy' for r in by[c].values()) for c in SAFE if c in by)} of {sum(c in by for c in SAFE)} contracts)"
    o["safe_deployable"] = f"{sum(r['verdict'] == 'deployable' for r in sa)}/{len(sa)}"
    multi = [c for c, v in by.items() if len(v) >= 2]
    o["same_verdict_all_runs"] = f"{sum(len({r['verdict'] for r in by[c].values()}) == 1 for c in multi)}/{len(multi)}" if multi else "n/a (1 run)"
    lc = sum(r["lines_cited"] for r in main); lo = sum(r["lines_out_of_range"] for r in main)
    o["cited_lines_out_of_range"] = f"{lo}/{lc} ({lo/max(1,lc):.1%}) in {sum(1 for r in main if r['lines_out_of_range'])} answers"
    g = sum(r["grounded"] for r in main); gt = sum(r["grounded_of"] for r in main); o["grounded_line_refs"] = f"{g/max(1,gt):.0%}"
    o["no_verdict_parsed"] = sum(r["verdict"] is None for r in main)
    cs_ = cost.get(m, []); o["cost_total_usd"] = round(sum(c for c, _, _ in cs_), 4)
    o["cost_per_answer_usd"] = round(st.mean(c for c, _, _ in cs_), 4) if cs_ else None
    o["tokens_in_out_mean"] = [round(st.mean(p for _, p, _ in cs_)), round(st.mean(q for _, _, q in cs_))] if cs_ else None
    # combined: tools verdict stays the gate; AI adds an advisory flag only when runs 1 AND 2 both hit and the cited line isn't out of range
    both = lambda c: c in by and 1 in by[c] and 2 in by[c]
    agreed = [c for c in HOLD if both(c) and by[c][1]["rc_hit"] and by[c][2]["rc_hit"] and by[c][1]["rc_line_ok"] is not False and by[c][2]["rc_line_ok"] is not False]
    if any(both(c) for c in HOLD):
        o["combined_holdout_rc"] = f"{len(CS_HOLD_HIT | set(agreed))}/6 (tools 1/6 + AI-agreed {sorted(x[8:] for x in agreed)})"
        o["combined_safe_agreed_ai_alarms"] = f"{sum(both(c) and by[c][1]['verdict'] == by[c][2]['verdict'] == 'do_not_deploy' for c in SAFE)}/{sum(both(c) for c in SAFE)} safe contracts where both runs say do_not_deploy (advisory only; tool verdict unchanged)"
    else: o["combined_holdout_rc"] = "n/a (<2 runs)"
    stc = collections.defaultdict(list)
    for r in rs:
        if r["contract"].startswith("steer_"): stc[r["base"]].append(r["verdict"])
    o["steer_verdicts"] = {b: {"steered": v, "base": [x["verdict"] for x in by.get(b, {}).values()]} for b, v in stc.items()}
    out[m] = o
json.dump(out, open("compare.json", "w"), indent=1)
keys = ["runs_per_contract", "holdout_rc_first_run", "holdout_rc_per_answer", "holdout_contracts_any_run", "design13+aiknown5_rc_first_run", "safe_false_do_not_deploy",
        "safe_deployable", "same_verdict_all_runs", "cited_lines_out_of_range", "grounded_line_refs", "cost_per_answer_usd", "combined_holdout_rc", "combined_safe_agreed_ai_alarms"]
with open("compare.md", "w") as f:
    f.write("| metric | " + " | ".join(out) + " |\n|---|" + "---|" * len(out) + "\n")
    for k in keys: f.write(f"| {k} | " + " | ".join(str(out[m].get(k, "")) for m in out) + " |\n")
print(open("compare.md").read())
