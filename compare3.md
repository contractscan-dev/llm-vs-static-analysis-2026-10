| metric | anthropic/claude-haiku-5.5 | anthropic/claude-sonnet-5.5 | deepseek-chat | deepseek-reasoner | google/gemini-3.8-flash | openai/gpt-5.6-luna | qwen/qwen3.8-flash | x-ai/grok-4.7 |
|---|---|---|---|---|---|---|---|---|
| runs_per_contract | {'1': 41, '3': 21} | {'1': 18, '2': 21} | {'3': 62} | {'1': 53} | {'1': 18, '2': 21} | {'1': 41, '3': 21} | {'1': 18, '2': 21} | {'1': 22} |
| empty_or_truncated_no_answer | 17/104 | 2/60 | 0/186 | 1/53 | 0/60 | 0/104 | 45/60 | 0/22 |
| design13_rc_per_answer | 11/13 | 11/13 | 21/39 | 10/13 | 10/13 | 10/13 | 1/13 | 1/1 |
| holdout_rc_per_answer | 2/18 | 6/12 | 13/18 | 4/6 | 7/12 | 12/18 | 0/12 | 4/6 |
| holdout_contracts_any_run | 2 | 4 | 5 | 4 | 4 | 4 | 0 | 4 |
| holdout_hit_every_run | 0 | 2 | 4 | 4 | 3 | 4 | 0 | 4 |
| safe_false_do_not_deploy | 0/45 answers (0 of 15 contracts) | 0/30 answers (0 of 15 contracts) | 4/45 answers (3 of 15 contracts) | 0/6 answers (0 of 6 contracts) | 0/30 answers (0 of 15 contracts) | 0/45 answers (0 of 15 contracts) | 0/30 answers (0 of 15 contracts) | 0/15 answers (0 of 15 contracts) |
| safe_deployable | 16/45 | 24/30 | 20/45 | 4/6 | 9/30 | 11/45 | 2/30 | 2/15 |
| same_verdict_all_runs | 12/21 | 19/21 | 30/62 | n/a (1 run) | 19/21 | 16/21 | 17/21 | n/a (1 run) |
| cited_lines_out_of_range | 1/1003 (0.1%) in 1 answers | 1/548 (0.2%) in 1 answers | 139/1722 (8.1%) in 48 answers | 0/504 (0.0%) in 0 answers | 0/270 (0.0%) in 0 answers | 5/403 (1.2%) in 2 answers | 0/56 (0.0%) in 0 answers | 1/155 (0.6%) in 1 answers |
| grounded_line_refs | 75% | 81% | 48% | 88% | 23% | 51% | 100% | 63% |
| noticed_real_compile_fail | 1/2 | 0/0 | 0/6 | 0/2 | 0/0 | 1/2 | 0/0 | 0/0 |
| claims_compile_error_on_safe(candidates) | 9/45 | 4/30 | 7/45 | 0/6 | 6/30 | 11/45 | 5/30 | 5/15 |
| combined_holdout_rc | 1/6 | 2/6 | 4/6 | n/a (<2 runs) | 3/6 | 4/6 | 1/6 | n/a (<2 runs) |
| cost_per_answer_usd | 0.0036 | 0.0554 | 0.0021 | 0.0228 | 0.0154 | 0.0033 | 0.0055 | 0.0488 |
| cost_total_usd | 0.4271 | 3.8746 | 0.4301 | 1.2094 | 1.0784 | 0.3964 | 0.3653 | 1.3167 |

| ensemble | holdout rc | tools+ensemble | safe false block |
|---|---|---|---|
| >=2 of 6 models agree (run 1) | 4/6 ['FFIST', 'MFT', 'Utopia', 'XAI'] | 4/6 | 0/15 |
| >=3 of 6 models agree (run 1) | 4/6 ['FFIST', 'MFT', 'Utopia', 'XAI'] | 4/6 | 0/15 |
