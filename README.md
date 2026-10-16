# Can you just ask an LLM? DeepSeek vs static analysis on 62 contracts (2026-10)

Data for the ContractScan experiment "Can you just ask an LLM if your contract is safe?". We pasted 62 Solidity contracts into DeepSeek with a realistic user prompt, ran each 3 times (chat) or once (reasoner), and graded the answers against known exploit root causes, a known-safe set, and ContractScan's production results.

See `summary.md` for setup, scoring rules and the key numbers.

## Contents
- `contracts/`
  - `ai_*`: 24 AI-written contracts from https://github.com/contractscan-dev/ai-solidity-experiment-2026-10
  - `hack_*`: 17 exploited contracts (DeFiHackLabs incidents; verified source via Sourcify)
  - `holdout_*`: 6 exploited contracts, frozen before rule design (`holdout_frozen.json`)
  - `safe_*`: 15 known-safe contracts (OpenZeppelin wizard-style, flattened solmate @89365b8, WETH9 for 0.8)
  - `steer_*`: 5 copies with a fake "audited" comment
- `raw/<model>/<contract>__r<run>.json`: every request timestamp and full API response (254 answers)
- `run_llm.py`: the exact prompt and API call. It needs `DEEPSEEK_API_KEY`.
- `score.py`, `manual_checks.json`: grading. Regex candidates are overridden by our manual reading.
- `metrics.py`, `metrics.json`: the headline numbers.
- `scored.csv` / `scored.json`: per answer.
- `per_contract.csv`: verdict and hit per run.
- `contractscan_results.csv`, `contractscan_compare_raw.json`: ContractScan production results on the same contracts.
- `cost.py`: token counts and a peak-rate upper bound. All calls ran off-peak.

`score.py` checks identifiers against vendored OpenZeppelin 4.9.6 / 5.7.0 sources at `vendor/` (from https://github.com/contractscan-dev/contractscan).

## Notes
- Prompt: `Is this contract safe to deploy? Answer verdict deployable/fix_first/do_not_deploy and list the issues with line numbers.` plus the source. No system prompt, default temperature.
- Models: `deepseek-chat` and `deepseek-reasoner` (API-reported model `deepseek-flash`, DeepSeek-V4.1-Flash). Calls ran 2026-10-16 05:05–05:19 UTC.
- Root-cause grading is our judgement. Disagree? Re-grade from `raw/`.
- Third-party contract sources keep their original licenses (mostly MIT / AGPL-3.0 / unlicensed verified code) and are included for research reproducibility. Our scripts and data are MIT.
- This is not an audit, and nothing here is a claim about currently deployed contracts beyond the public post-mortems.
