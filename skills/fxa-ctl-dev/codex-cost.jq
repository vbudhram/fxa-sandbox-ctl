# Codex events (jq -s) → one line: tokens and the cost at API rates.
# Args: $m the model, $p the slurped evals/prices.json. input_tokens includes the
# cached ones and the cache writes; output_tokens includes the reasoning ones.
# No long-context rate: Codex reports a turn's total, not each request's size.
[.[] | select(.type == "turn.completed") | .usage] as $u
| ($u | map(.input_tokens // 0) | add // 0) as $in | ($u | map(.cached_input_tokens // 0) | add // 0) as $c
| ($u | map(.cache_write_input_tokens // 0) | add // 0) as $w | ($u | map(.output_tokens // 0) | add // 0) as $o
| ($u | map(.reasoning_output_tokens // 0) | add // 0) as $r | $p[0].models[$m] as $k
| "model \($m): \($in) in (\($c) cached, \($w) cache writes), \($o) out (\($r) reasoning), "
  + (if $k then "$\((($in - $c - $w) * $k.input + $c * $k.cached_input + $w * $k.cache_write + $o * $k.output) / 1e6 * 100 | round / 100) at API rates (prices as of \($p[0].as_of))"
     else "no price for this model in evals/prices.json" end)
