#!/usr/bin/env bash
# Model aliases (`~/.mlx-serve/model-aliases.json`): a short id a client can use
# instead of the checkpoint directory's name, advertised on the model's
# `/v1/models` row and accepted by every request that names a model.
#
# Runs under a private HOME so the real alias file is never touched. MODEL_B
# (the server default, distinct from the alias target) makes the routing arm
# meaningful; without it that one check is skipped.
#
# Usage: ./tests/test_model_aliases.sh [port]
set -uo pipefail
PORT="${1:-11387}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/mlx-serve"
[ -x "$BIN" ] || { echo "FAIL: build first (zig build -Doptimize=ReleaseFast)"; exit 1; }

MODELS_ROOT="${MODELS_ROOT:-$HOME/.mlx-serve/models}"
MODEL_A="${MODEL_A:-$MODELS_ROOT/mlx-community/Qwen2.5-0.5B-Instruct-4bit}"
MODEL_B="${MODEL_B:-$MODELS_ROOT/mlx-community/Qwen3.5-0.8B-MLX-4bit}"
if [ ! -f "$MODEL_A/config.json" ]; then
    echo "SKIP: needs a local chat model (MODEL_A=$MODEL_A)"
    exit 0
fi
TWO=0; [ -f "$MODEL_B/config.json" ] && TWO=1
# Discovery registers the two-level `org/name` id, which is what the file must
# name — or the model's absolute path.
ID_A="${MODEL_A#"$MODELS_ROOT"/}"

PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
check() {
    if [ "$2" = "1" ]; then PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC} $1"
    else FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; fi
}

FAKE_HOME="$(mktemp -d)"
mkdir -p "$FAKE_HOME/.mlx-serve"
ALIASES="$FAKE_HOME/.mlx-serve/model-aliases.json"
LOG="$FAKE_HOME/server.log"
SRV=""
cleanup() {
    [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
    pkill -f "mlx-serve.*--port $PORT" 2>/dev/null
    rm -rf "$FAKE_HOME"
}
trap cleanup EXIT
pkill -f "mlx-serve.*--port $PORT" 2>/dev/null
sleep 0.5

# alias by id, alias by absolute path, a dangling alias, and an attempt to take
# over "mlx-serve" — the built-in default-model alias, which stays reserved.
write_aliases() {
    cat >"$ALIASES" <<JSON
{ "qwen-tiny": "$ID_A", "by-path": "$MODEL_A", "gone": "org/not-on-disk", "mlx-serve": "$ID_A" }
JSON
}
write_aliases

# MODEL_B is the boot model, so the DEFAULT id resolves to a different entry
# than the aliases: a request that ignored them lands on B.
BOOT_MODEL="$MODEL_A"; [ "$TWO" = "1" ] && BOOT_MODEL="$MODEL_B"
HOME="$FAKE_HOME" "$BIN" --serve --model "$BOOT_MODEL" --model-dir "$MODELS_ROOT" --port "$PORT" --log-file off >"$LOG" 2>&1 &
SRV=$!
UP=0
for _ in $(seq 1 240); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { UP=1; break; }
    kill -0 "$SRV" 2>/dev/null || break
    sleep 0.5
done
[ "$UP" = "1" ] || { echo "FAIL: server never became healthy"; tail -5 "$LOG"; exit 1; }

models() { curl -s "http://127.0.0.1:$PORT/v1/models"; }
field() { # field <model id> <field> — one field of that row (None when absent)
    models | python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']:
    if m['id'] == sys.argv[1]:
        v = m.get(sys.argv[2])
        print(json.dumps(sorted(v)) if isinstance(v, list) else v)
        break
" "$1" "$2"
}
loaded() { [ "$(field "$1" loaded)" = "True" ] && echo 1 || echo 0; }
post() { # post <route> <json> — the response's http code
    curl -s -o /dev/null -w '%{http_code}' --max-time 300 -X POST "http://127.0.0.1:$PORT/$1" \
        -H 'Content-Type: application/json' -d "$2"
}
chat_http() { # chat_http <model value> — http code of a tiny chat request
    post v1/chat/completions "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}"
}

# [1] the listing advertises the names a client may use, id- and path-keyed alike
check "[1] row advertises both aliases (got $(field "$ID_A" aliases))" \
    "$([ "$(field "$ID_A" aliases)" = '["by-path", "qwen-tiny"]' ] && echo 1 || echo 0)"
check "[1] boot logs the alias file" "$(grep -q '\[aliases\] [0-9]* model alias(es)' "$LOG" && echo 1 || echo 0)"

# [2] the alias routes to ITS model, not to the server default
CODE="$(chat_http qwen-tiny)"
check "[2] chat with model=qwen-tiny -> 200 (got $CODE)" "$([ "$CODE" = "200" ] && echo 1 || echo 0)"
check "[2] it loaded A's entry (loaded $(loaded "$ID_A"))" "$([ "$(loaded "$ID_A")" = "1" ] && echo 1 || echo 0)"
ID_B="$(basename "$MODEL_B")"
if [ "$TWO" = "1" ]; then
    post v1/unload-model "{\"model\":\"$ID_B\"}" >/dev/null
    sleep 1
    CODE="$(chat_http by-path)"
    check "[2] chat with model=by-path -> 200 (got $CODE)" "$([ "$CODE" = "200" ] && echo 1 || echo 0)"
    check "[2] the default B stayed unloaded (loaded $(loaded "$ID_B"))" "$([ "$(loaded "$ID_B")" = "0" ] && echo 1 || echo 0)"
else
    echo "  SKIP [2] routing vs. the default model (needs MODEL_B=$MODEL_B)"
fi

# [3] an alias whose target isn't registered is not a model: it never routes to
# A. (An unknown id keeps its pinned behavior — the default model answers.)
post v1/unload-model "{\"model\":\"$ID_A\"}" >/dev/null
sleep 1
CODE="$(chat_http gone)"
if [ "$TWO" = "1" ]; then
    check "[3] dangling alias -> $CODE with A left cold (loaded $(loaded "$ID_A"))" \
        "$([ "$CODE" = "200" ] && [ "$(loaded "$ID_A")" = "0" ] && echo 1 || echo 0)"
else
    # A is the server default here, so the fallback reloads it: not a signal.
    check "[3] dangling alias -> $CODE, the default answers (pinned fallback)" \
        "$([ "$CODE" = "200" ] && echo 1 || echo 0)"
fi
check "[3] a dangling alias is not advertised (got $(field "$ID_A" aliases))" \
    "$([ "$(field "$ID_A" aliases)" = '["by-path", "qwen-tiny"]' ] && echo 1 || echo 0)"
chat_http qwen-tiny >/dev/null

# [4] "mlx-serve" is the built-in default-model alias and the file cannot take it
CODE="$(chat_http mlx-serve)"
check "[4] model=mlx-serve still answers with the default -> 200 (got $CODE)" "$([ "$CODE" = "200" ] && echo 1 || echo 0)"
check "[4] the row carries no \"mlx-serve\" alias (got $(field "$ID_A" aliases))" \
    "$([ "$(field "$ID_A" aliases)" = '["by-path", "qwen-tiny"]' ] && echo 1 || echo 0)"

# [5] edit the file + /v1/models/rescan applies it without a restart
echo '{ "renamed": "mlx-community/nonexistent-quant" }' >"$ALIASES"
CODE="$(post v1/models/rescan '{}')"
check "[5] rescan -> 200 (got $CODE)" "$([ "$CODE" = "200" ] && echo 1 || echo 0)"
check "[5] the removed names are gone from the row (got $(field "$ID_A" aliases))" \
    "$([ "$(field "$ID_A" aliases)" = "None" ] && echo 1 || echo 0)"
kill -0 "$SRV" 2>/dev/null; check "[5] server never restarted" "$([ $? = 0 ] && echo 1 || echo 0)"

echo "{ \"renamed\": \"$ID_A\" }" >"$ALIASES"
post v1/models/rescan '{}' >/dev/null
check "[5] a new alias appears on the row (got $(field "$ID_A" aliases))" \
    "$([ "$(field "$ID_A" aliases)" = '["renamed"]' ] && echo 1 || echo 0)"
CODE="$(chat_http renamed)"
check "[5] and resolves -> 200 (got $CODE)" "$([ "$CODE" = "200" ] && echo 1 || echo 0)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
