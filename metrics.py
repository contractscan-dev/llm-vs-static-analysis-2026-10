import json, collections, statistics as st
R = json.load(open("scored.json"))
CONF = ["hack_" + x for x in "MulticallWithETH LABUBUToken SUT AIZPTToken APEMAGA RedKeysCoin MyAi FireToken Bitpaidio UeriiToken H2O Uwerx PLN".split()]
UNC = ["hack_" + x for x in "DOGGO HANAToken DDCoin FIL314".split()]
HOLD = ["holdout_" + x for x in "MFT Utopia FFIST XAI LW Grizzifi".split()]
AIK = ["ai_dex_launcher_1_chat", "ai_eth_vault_3_chat", "ai_staking_1_chat", "ai_dex_launcher_1_reasoner", "ai_staking_1_reasoner"]
cs = {r["file"].split("/")[-1][:-4]: r for r in json.load(open("contractscan_compare_raw.json"))}
out = {}
def by(model, cs_):
    return [r for r in R if r["model"] == model and r["contract"] in cs_]
for model in ("deepseek-chat", "deepseek-reasoner"):
    m = {}
    for name, S in (("design13", CONF), ("holdout6", HOLD), ("ai_known5", AIK)):
        rs = by(model, S); m[name] = {"answers": len(rs), "rc_hits": sum(r["rc_hit"] for r in rs), "rate": round(sum(r["rc_hit"] for r in rs) / max(1, len(rs)), 2),
                                     "contracts_hit_every_run": sum(all(r["rc_hit"] for r in rs if r["contract"] == c) for c in S if any(r["contract"] == c for r in rs)),
                                     "contracts_hit_any_run": sum(any(r["rc_hit"] for r in rs if r["contract"] == c) for c in S)}
        lo = [r["rc_line_ok"] for r in rs if r["rc_line_ok"] is not None]; m[name]["rc_line_within_5"] = f"{sum(lo)}/{len(lo)}"
    safe = [r for r in R if r["model"] == model and r["contract"].startswith("safe_")]
    m["safe"] = {"answers": len(safe), "verdicts": dict(collections.Counter(r["verdict"] for r in safe))}
    allr = [r for r in R if r["model"] == model and not r["contract"].startswith("steer_")]
    m["verdicts_all"] = dict(collections.Counter(r["verdict"] for r in allr))
    m["lines_cited"] = sum(r["lines_cited"] for r in allr); m["lines_out_of_range"] = sum(r["lines_out_of_range"] for r in allr)
    m["answers_with_out_of_range_line"] = sum(1 for r in allr if r["lines_out_of_range"])
    g = sum(r["grounded"] for r in allr); gt = sum(r["grounded_of"] for r in allr); m["grounded_line_refs"] = f"{g}/{gt} ({g/max(1,gt):.0%})"
    m["avg_issues_with_line_refs"] = round(st.mean(r["n_issues"] for r in allr), 1)
    if model == "deepseek-chat":
        cons = collections.defaultdict(list)
        for r in allr: cons[r["contract"]].append(r)
        full = [c for c, v in cons.items() if len(v) == 3]
        m["verdict_same_all_3_runs"] = f"{sum(len({r['verdict'] for r in cons[c]}) == 1 for c in full)}/{len(full)}"
        rcc = [c for c in full if c in CONF + HOLD + AIK]
        m["rc_hit_same_all_3_runs"] = f"{sum(len({r['rc_hit'] for r in cons[c]}) == 1 for c in rcc)}/{len(rcc)}"
        st_ = {}
        for r in R:
            if r["model"] == model and r["contract"].startswith("steer_"):
                st_.setdefault(r["base"], {"steer": [], "base": []})["steer"].append((r["verdict"], r["rc_hit"]))
        for b in st_:
            st_[b]["base"] = [(r["verdict"], r["rc_hit"]) for r in cons[b]]
        m["steer"] = st_
    out[model] = m
# ContractScan (production scanner, compare_raw after) on the same sets
def csv_(c): r = cs.get(c.split("_", 1)[1]) ; return r["after"]["verdict"] if r else None
CS_RC = {"design13": 11, "holdout6": 1, "ai_known5": 5}
out["contractscan"] = {"rc_hits": CS_RC, "safe15_verdicts": dict(collections.Counter(csv_(c) for c in {r["contract"] for r in R if r["contract"].startswith("safe_")})),
                       "design13_verdicts": dict(collections.Counter(csv_(c) for c in CONF)), "holdout_verdicts": dict(collections.Counter(csv_(c) for c in HOLD))}
json.dump(out, open("metrics.json", "w"), indent=1); print(json.dumps(out, indent=1))
