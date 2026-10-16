"""Score LLM answers: verdict, root-cause hit (regex candidates, then manually checked: see manual_checks.json),
false alarms on the safe set, hallucination checks (line out of range, identifiers that do not exist, cited line not
containing the code the issue talks about), and verdict consistency across 3 runs."""
import json, glob, re, collections, csv, pathlib
SRC = {p.stem: p.read_text() for p in pathlib.Path("contracts").glob("*.sol")}
OZTXT = "\n".join(p.read_text() for d in ("vendor/oz-5.7.0", "vendor/oz-4.9.6") for p in pathlib.Path(d).rglob("*.sol"))
# root-cause patterns: all regexes in the tuple must match the same paragraph (issue item)
RC = {
 "hack_MulticallWithETH": (r"aggregate", r"arbitrary|any (target|address|contract|call)|approv|calldata"),
 "hack_LABUBUToken": (r"self[- ]?transfer|sender\s*==\s*recipient|recipient\s*==\s*sender|to (yourself|themsel|itself|oneself)|same address|from\s*==\s*to|transfers? to (him|her)self",),
 "hack_SUT": (r"buyTokens|price", r"precision|round|truncat|divi(de|sion) before|before multipl|/\s*1e18|zero cost|for free|pay(s)? (nothing|0)"),
 "hack_AIZPTToken": (r"msg\.value", r"address\(this\)\.balance|contract('s)? (ETH )?balance", r"already|includ|after|inflat|added"),
 "hack_APEMAGA": (r"family", r"burn|anyone|any (account|address)|arbitrary|zero|_approve_|balance"),
 "hack_RedKeysCoin": (r"random|prng|predictab|block\.(timestamp|prevrandao|difficulty|number)",),
 "hack_DOGGO": (r"swap ?back|swapTokensForEth|auto(matic)?[- ]?swap|swapAndLiquify|contract('s)? token balance", r"sandwich|manipulat|front[- ]?run|MEV|price impact|slippage|amountOutMin|0 min"),
 "hack_HANAToken": (r"swap ?back|swapTokensForEth|auto(matic)?[- ]?swap|swapAndLiquify|contract('s)? token balance", r"sandwich|manipulat|front[- ]?run|MEV|price impact|slippage|amountOutMin|0 min"),
 "hack_MyAi": (r"tokenTransfer", r"_from|from address|arbitrary|allowance|anyone|any address"),
 "hack_FireToken": (r"sync", r"pair|uniswapV2Pair|reserve"),
 "hack_DDCoin": (r"listItem|invite|_invite", r"flash|manipulat|bypass|limit|abuse"),
 "hack_FIL314": (r"price|reserve|getAmountOut|swap", r"manipulat|flash|sandwich|validation|reentr"),
 "hack_Bitpaidio": (r"Lock_Token|lock", r"end_?time|unlock time|timestamp|existing lock|overwrit|reset|extend|instantly|immediately"),
 "hack_UeriiToken": (r"\bmint\b", r"anyone|any (user|account|address|one)|no access|unrestricted|without (any )?(access|restriction|permission|check)|unprotected|public"),
 "hack_H2O": (r"random|predictab|block\.(timestamp|prevrandao|difficulty|number)",),
 "hack_Uwerx": (r"burn", r"pair|pool|uniswapPoolAddress|liquidity"),
 "hack_PLN": (r"transferFrom", r"zero|0 amount|amount (of )?0|arbitrary|allowance|any address|anyone"),
 "holdout_MFT": (r"burnLiquidityPairTokens|burn.{0,60}(pair|pool|liquidity)|(pair|pool|liquidity).{0,60}burn", r"sync|reserve|drain|manipulat"),
 "holdout_Utopia": (r"airdrop", r"random|predict|pair|overwrit|_balances|manipulat"),
 "holdout_FFIST": (r"airdrop", r"random|predict|pair|overwrit|_balances|manipulat"),
 "holdout_Grizzifi": (r"referr|upline|sponsor|team", r"withdraw|bonus|reward|sybil|self|fake|loop|cycle|abuse"),
 "holdout_LW": (r"thanPrice|getTokenPrice|price|receive", r"manipulat|flash|skim|spot|balance"),
 "holdout_XAI": (r"burn", r"reflect|rOwned|_rTotal|rate|pair|sync|supply"),
 # AI contracts with known real issues from our hand triage (ai-solidity-experiment-2026-10/review.csv) + the 2 TestToken mints
 "ai_dex_launcher_1_chat": (r"reentr", r"swap|removeLiquidity"),
 "ai_eth_vault_3_chat": (r"emergencyWithdraw|owner", r"all|entire|whole|users'?|drain|rug|locked"),
 "ai_staking_1_chat": (r"reward|APR", r"principal|insolv|reserve|fund|other (users|stakers)|not (backed|funded)|deposit"),
 "ai_dex_launcher_1_reasoner": (r"\bmint\b", r"anyone|any (user|account|address|one)|no access|unrestricted|without (any )?(access|restriction|check)|unprotected"),
 "ai_staking_1_reasoner": (r"\bmint\b", r"anyone|any (user|account|address|one)|no access|unrestricted|without (any )?(access|restriction|check)|unprotected"),
}
ROOT_LINES = {"hack_LABUBUToken": (119, 141), "hack_APEMAGA": (221, 249), "hack_UeriiToken": (489, 489), "hack_FireToken": (266, 276),
              "hack_Uwerx": (480, 497), "hack_AIZPTToken": (167, 183), "hack_MulticallWithETH": (17, 19), "hack_SUT": (144, 144),
              "hack_MyAi": (326, 338), "hack_Bitpaidio": (341, 356), "hack_H2O": (509, 531), "holdout_MFT": (648, 662)}
V = re.compile(r"(do[_ ]not[_ ]deploy|fix[_ ]first|deployable)", re.I)
def verdict(t):
    m = re.search(r"verdict[^a-z\n]{0,15}" + V.pattern, t, re.I) or V.search(t)
    return m.group(1).lower().replace(" ", "_") if m else None
def paragraphs(t):  # issue items: split on headings / numbered / bullet starts
    return [p for p in re.split(r"\n(?=\s*(?:#+ |\*\*\d|\d+[.)] |[-*] \*\*|\*\*[A-Z]))", t) if p.strip()]
def lines_cited(p):
    out = []
    for m in re.finditer(r"\b(?:[Ll]ines?|L)\s?(\d{1,5})(?:\s*(?:[-–—]|to)\s*L?(\d{1,5}))?", p):
        a = int(m.group(1)); b = int(m.group(2) or a); out.append((a, max(a, b)))
    return out
KW = set("""if else for while return function require assert revert emit mapping address uint uint256 uint8 int bool string bytes bytes32 memory storage calldata public private internal external view pure payable returns true false msg sender value this block timestamp new delete constructor modifier event struct enum interface contract library import pragma solidity override virtual abstract is using type keccak256 abi encode encodePacked transfer send call balance length push pop tx origin gasleft selfdestruct super""".split())
def idents(p):
    return {x for x in re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)\s*\(", p)} | {x for x in re.findall(r"`([A-Za-z_][A-Za-z0-9_]{3,})`", p)}
def run_one(f):
    j = json.load(open(f)); c = j["contract"]; r = j["response"]
    if "choices" not in r: return None
    t = r["choices"][0]["message"]["content"] or ""; src = SRC[c]; L = src.split("\n"); n = len(L)
    shift = 1 if c.startswith("steer_") else 0
    base = ("hack_" + c[6:] if ("hack_" + c[6:]) in SRC else "ai_" + c[6:]) if c.startswith("steer_") else c
    ps = paragraphs(t); cited = [(p, a, b) for p in ps for a, b in lines_cited(p)]
    out_range = sum(1 for _, a, b in cited if b > n)
    ids = set().union(*[idents(p) for p in ps]) if ps else set()
    hay = src + ("\n" + OZTXT if "@openzeppelin" in src else "")
    ghost = sorted(i for i in ids if i not in KW and not re.search(r"\b" + re.escape(i) + r"\b", hay))
    # grounded: a cited range (+-3) contains at least one identifier named in the same item
    g_tot = g_ok = 0
    for p, a, b in cited:
        its = [i for i in idents(p) if i not in KW and re.search(r"\b" + re.escape(i) + r"\b", src)]
        if not its or b > n: continue
        g_tot += 1; seg = "\n".join(L[max(0, a - 4):min(n, b + 3)])
        g_ok += any(re.search(r"\b" + re.escape(i) + r"\b", seg) for i in its)
    hit, hit_par = False, None
    if base in RC:
        for p in ps:
            if all(re.search(x, p, re.I | re.S) for x in RC[base]): hit, hit_par = True, p[:400]; break
    line_ok = None
    if hit and base in ROOT_LINES:
        lo, hi = ROOT_LINES[base]; lo += shift; hi += shift
        line_ok = any(a - 5 <= hi and b + 5 >= lo for a, b in lines_cited(hit_par or ""))
    return {"model": j["model_requested"], "contract": c, "base": base, "run": j["run"], "verdict": verdict(t), "n_issues": len([p for p in ps if lines_cited(p)]),
            "lines_cited": len(cited), "lines_out_of_range": out_range, "ghost_identifiers": ghost, "grounded": g_ok, "grounded_of": g_tot,
            "rc_hit": hit, "rc_line_ok": line_ok, "rc_par": hit_par, "chars": len(t)}
rows = [x for x in (run_one(f) for f in sorted(glob.glob("raw/*/*.json"))) if x]
OV = json.load(open("manual_checks.json"))["overrides"]
for r in rows:
    v = OV.get(r["model"], {}).get(r["contract"])
    r["rc_regex"] = r["rc_hit"]
    if v is not None:
        r["rc_hit"] = bool(v[r["run"] - 1]); r["rc_manual"] = True
        if not r["rc_hit"]: r["rc_line_ok"] = None
json.dump(rows, open("scored.json", "w"), indent=1)
with open("scored.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=[k for k in rows[0] if k != "rc_par"], extrasaction="ignore"); w.writeheader(); w.writerows(rows)
print(len(rows), "answers scored")
