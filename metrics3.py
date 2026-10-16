"""Multi-model extras on top of compare.json: empty/truncated answers, compile checks, tools+model 2-run filter, cross-model ensembles. Writes compare3.json / compare3.md."""
import json, glob, re, collections
from metrics import CONF, HOLD, AIK
R = json.load(open("scored.json")); C = json.load(open("compare.json"))
SAFE = sorted({r["contract"] for r in R if r["contract"].startswith("safe_")})
REAL_FAIL = ["ai_dex_launcher_3_chat", "ai_nft_allowlist_1_reasoner"]; CS_HOLD = {"holdout_MFT"}
FAKE = re.compile(r"(will not|won't|does not|doesn't|fails? to|cannot) compile|compil(e|ation) (error|fail)", re.I)
txt = {}
for f in glob.glob("raw/*/*.json"):
    j = json.load(open(f)); r = j["response"]
    ch = (r.get("choices") or [{}])[0]; txt[(j["model_requested"], j["contract"], j["run"])] = ((ch.get("message") or {}).get("content") or "", ch.get("finish_reason"))
out = {}
for m in sorted({r["model"] for r in R}):
    rs = [r for r in R if r["model"] == m and not r["contract"].startswith("steer_")]
    by = collections.defaultdict(dict)
    for r in rs: by[r["contract"]][r["run"]] = r
    o = dict(C[m]); t = lambda r: txt[(m, r["contract"], r["run"])]
    o["empty_or_truncated_no_answer"] = f"{sum(len(t(r)[0]) < 200 for r in rs)}/{len(rs)}"
    o["design13_rc_per_answer"] = f"{sum(r['rc_hit'] for c in CONF for r in by.get(c,{}).values())}/{sum(len(by.get(c,{})) for c in CONF)}"
    o["noticed_real_compile_fail"] = f"{sum(bool(FAKE.search(t(r)[0])) for c in REAL_FAIL for r in by.get(c,{}).values())}/{sum(len(by.get(c,{})) for c in REAL_FAIL)}"
    o["claims_compile_error_on_safe(candidates)"] = f"{sum(bool(FAKE.search(t(r)[0])) for c in SAFE for r in by.get(c,{}).values())}/{sum(len(by.get(c,{})) for c in SAFE)}"
    h = {c: [r["rc_hit"] for r in by.get(c, {}).values()] for c in HOLD}
    o["holdout_hit_every_run"] = sum(bool(v) and all(v) for v in h.values())
    out[m] = o
# cross-model ensemble on holdout: a holdout root cause counts if >=k distinct models flag it in their run 1; safe false-block if >=k models say do_not_deploy in run 1
models = [m for m in out if m != "deepseek-reasoner" and not m.startswith("qwen")]
r1 = {(r["model"], r["contract"]): r for r in R if r["run"] == 1}
ens = {}
for k in (2, 3):
    hh = [c for c in HOLD if sum(bool(r1.get((m, c), {}).get("rc_hit")) for m in models) >= k]
    sb = [c for c in SAFE if sum(r1.get((m, c), {}).get("verdict") == "do_not_deploy" for m in models) >= k]
    ens[f">={k} of {len(models)} models agree (run 1)"] = {"holdout_rc": f"{len(hh)}/6 {sorted(x[8:] for x in hh)}", "tools+ensemble holdout": f"{len(CS_HOLD|set(hh))}/6", "safe_false_block": f"{len(sb)}/15"}
json.dump({"per_model": out, "ensemble": ens, "ensemble_models": models}, open("compare3.json", "w"), indent=1)
keys = ["runs_per_contract","empty_or_truncated_no_answer","design13_rc_per_answer","holdout_rc_per_answer","holdout_contracts_any_run","holdout_hit_every_run","safe_false_do_not_deploy","safe_deployable","same_verdict_all_runs","cited_lines_out_of_range","grounded_line_refs","noticed_real_compile_fail","claims_compile_error_on_safe(candidates)","combined_holdout_rc","cost_per_answer_usd","cost_total_usd"]
with open("compare3.md", "w") as f:
    f.write("| metric | " + " | ".join(out) + " |\n|---|" + "---|" * len(out) + "\n")
    for k in keys: f.write(f"| {k} | " + " | ".join(str(out[m].get(k, "")).split(" (tools")[0] for m in out) + " |\n")
    f.write("\n| ensemble | holdout rc | tools+ensemble | safe false block |\n|---|---|---|---|\n")
    for k, v in ens.items(): f.write(f"| {k} | {v['holdout_rc']} | {v['tools+ensemble holdout']} | {v['safe_false_block']} |\n")
print(open("compare3.md").read())
