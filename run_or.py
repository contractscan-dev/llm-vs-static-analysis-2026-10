"""Same user prompt as run_llm.py, via OpenRouter. raw/<model id with / -> __>/<contract>__r<k>.json.
Budget guard: stops when account usage exceeds START_USAGE + CAP (credits endpoint, checked every batch)."""
import json, os, sys, time, pathlib, datetime, httpx, threading, concurrent.futures as cf
from run_llm import PROMPT
KEY = os.environ["OPENROUTER_API_KEY"]  # never printed
H = {"Authorization": f"Bearer {KEY}", "X-Title": "ContractScan LLM experiment"}
CAP = float(os.environ.get("OR_CAP", "1.9")); STATE = pathlib.Path("or_budget.json")
def usage(): return httpx.get("https://openrouter.ai/api/v1/credits", headers=H, timeout=30).json()["data"]
if not STATE.exists(): u = usage(); STATE.write_text(json.dumps({"start_usage": u["total_usage"], "credits": u["total_credits"], "utc": datetime.datetime.utcnow().isoformat()}))
START = json.loads(STATE.read_text())["start_usage"]; spent = [0.0]; lock = threading.Lock(); stop = [False]
def local_spent():
    import glob
    return sum((json.load(open(f))["response"].get("usage") or {}).get("cost") or 0 for f in glob.glob("raw/*__*/*.json"))
def call(model, src):
    body = {"model": model, "messages": [{"role": "user", "content": PROMPT.format(src=src)}], "max_tokens": 12000, "usage": {"include": True}}
    for t in range(3):
        try:
            r = httpx.post("https://openrouter.ai/api/v1/chat/completions", headers=H, json=body, timeout=300)
            if r.status_code == 200 and r.json().get("choices"): return r.json()
            err = f"http {r.status_code}: {r.text[:200]}"
        except Exception as e: err = str(e)[:200]
        time.sleep(5 * (t + 1))
    return {"error": err}
def job(a):
    model, f, k = a
    if stop[0]: return None
    out = pathlib.Path(f"raw/{model.replace('/', '__')}/{pathlib.Path(f).stem}__r{k}.json")
    if out.exists() and "error" not in json.load(open(out))["response"]: return None
    out.parent.mkdir(parents=True, exist_ok=True)
    t = datetime.datetime.now(datetime.timezone.utc).isoformat(); r = call(model, open(f).read())
    json.dump({"model_requested": model, "contract": pathlib.Path(f).stem, "run": k, "utc": t, "response": r}, open(out, "w"), indent=1)
    u = r.get("usage", {}) or {}
    with lock: spent[0] += u.get("cost") or 0
    return (out.name, r.get("model"), u.get("prompt_tokens"), u.get("completion_tokens"), u.get("cost"), r.get("error"))
if __name__ == "__main__":
    model, runs, listfile = sys.argv[1], [int(x) for x in sys.argv[2].split(",")], sys.argv[3]
    files = [f"contracts/{n}.sol" for n in open(listfile).read().split()]
    jobs = [(model, f, k) for k in runs for f in files]
    for i in range(0, len(jobs), 12):
        tot = local_spent()
        if tot > CAP: print(f"BUDGET STOP: experiment spend ${tot:.3f} > cap ${CAP}"); break
        with cf.ThreadPoolExecutor(12) as ex:
            for r in ex.map(job, jobs[i:i+12]):
                if r: print(*r, flush=True)
    print(f"this invocation reported cost ${spent[0]:.4f}; experiment total (credits endpoint, lags) ${usage()['total_usage']-START:.4f}")
