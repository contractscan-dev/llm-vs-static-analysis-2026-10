"""Ask DeepSeek, the way a user would, whether each contract is safe to deploy. Raw responses go to raw/<model>/<contract>__r<k>.json"""
import json, os, sys, time, pathlib, datetime, httpx, concurrent.futures as cf
KEY = os.environ["DEEPSEEK_API_KEY"]   # never printed
PROMPT = ("Is this contract safe to deploy? Answer verdict deployable/fix_first/do_not_deploy and list the issues with line numbers.\n\n"
          "```solidity\n{src}\n```")
def call(model, src):
    body = {"model": model, "messages": [{"role": "user", "content": PROMPT.format(src=src)}]}   # default temperature, like a user
    for t in range(4):
        try:
            r = httpx.post("https://api.deepseek.com/chat/completions", headers={"Authorization": f"Bearer {KEY}"}, json=body, timeout=900)
            if r.status_code == 200: return r.json()
            err = f"http {r.status_code}: {r.text[:200]}"
        except Exception as e: err = str(e)[:200]
        time.sleep(5 * (t + 1))
    return {"error": err}
def job(a):
    model, f, k = a
    out = pathlib.Path(f"raw/{model}/{pathlib.Path(f).stem}__r{k}.json")
    if out.exists() and "error" not in json.load(open(out))["response"]: return None
    out.parent.mkdir(parents=True, exist_ok=True)
    t = datetime.datetime.now(datetime.timezone.utc).isoformat(); r = call(model, open(f).read())
    json.dump({"model_requested": model, "contract": pathlib.Path(f).stem, "run": k, "utc": t, "response": r}, open(out, "w"), indent=1)
    u = r.get("usage", {}); return (out.name, r.get("model"), u.get("prompt_tokens"), u.get("prompt_cache_hit_tokens"), u.get("completion_tokens"), r.get("error"))
if __name__ == "__main__":
    model, runs, pattern = sys.argv[1], int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "*"
    files = sorted(str(p) for p in pathlib.Path("contracts").glob(pattern + ".sol"))
    jobs = [(model, f, k) for k in range(1, runs + 1) for f in files]
    with cf.ThreadPoolExecutor(12) as ex:
        for r in ex.map(job, jobs):
            if r: print(*r, flush=True)
