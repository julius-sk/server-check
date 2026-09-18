#!/usr/bin/env bash
# =============================================================================
# setup-opencode.sh  —  one-shot OpenCode setup on a new Linux machine
#
# Usage:
#   bash setup-opencode.sh                       # defaults: X3 server, auto-find binary
#   bash setup-opencode.sh --host 192.168.3.73   # point at a different LLM server
#   bash setup-opencode.sh --tarball /tmp/opencode-linux-x64.tar.gz
#   bash setup-opencode.sh --config-only         # rewrite config, skip install/tests
#
# Binary lookup order:
#   1. --tarball PATH
#   2. opencode-linux-x64.tar.gz next to this script
#   3. already-installed ~/.opencode/bin/opencode
#   4. download from GitHub (often blocked on the lab network)
# =============================================================================
set -euo pipefail

LLM_HOST="192.168.3.73"
LLM_PORT="8000"
MODEL_ID="Qwen3-Coder-480B-A35B-Instruct-FP8"
OC_VERSION="1.18.31"
TARBALL=""
CONFIG_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        LLM_HOST="$2"; shift 2 ;;
    --port)        LLM_PORT="$2"; shift 2 ;;
    --model)       MODEL_ID="$2"; shift 2 ;;
    --tarball)     TARBALL="$2"; shift 2 ;;
    --version)     OC_VERSION="$2"; shift 2 ;;
    --config-only) CONFIG_ONLY=1; shift ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.opencode/bin"
BIN="$BIN_DIR/opencode"
CFG_DIR="$HOME/.config/opencode"
CFG="$CFG_DIR/opencode.jsonc"
BASE_URL="http://${LLM_HOST}:${LLM_PORT}/v1"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ok: %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m    FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. binary
if [ "$CONFIG_ONLY" -eq 0 ]; then
  say "1/5 install opencode binary"
  mkdir -p "$BIN_DIR"

  if [ -z "$TARBALL" ] && [ -f "$HERE/opencode-linux-x64.tar.gz" ]; then
    TARBALL="$HERE/opencode-linux-x64.tar.gz"
  fi

  if [ -n "$TARBALL" ]; then
    [ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
    tar -xzf "$TARBALL" -C "$BIN_DIR"
    ok "extracted $TARBALL"
  elif [ -x "$BIN" ]; then
    ok "already installed: $("$BIN" --version 2>/dev/null || echo unknown)"
  else
    URL="https://github.com/anomalyco/opencode/releases/download/v${OC_VERSION}/opencode-linux-x64.tar.gz"
    TMP="$(mktemp -d)"
    echo "    downloading $URL"
    if curl -fL --http1.1 --retry 3 --retry-delay 3 --max-time 600 -o "$TMP/oc.tar.gz" "$URL" \
       || wget -q -O "$TMP/oc.tar.gz" "$URL"; then
      tar -xzf "$TMP/oc.tar.gz" -C "$BIN_DIR"
      ok "downloaded and extracted"
    else
      fail "cannot reach GitHub. Copy opencode-linux-x64.tar.gz next to this script (or pass --tarball) and rerun."
    fi
    rm -rf "$TMP"
  fi

  chmod +x "$BIN"
  "$BIN" --version >/dev/null 2>&1 || fail "binary does not run (wrong arch or corrupt file)"
  ok "opencode $("$BIN" --version)"

  # PATH for future shells (bash and zsh), idempotent
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -q '\.opencode/bin' "$rc" || echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$rc"
  done
  ok "PATH line ensured in shell rc"
fi

# ---------------------------------------------------------------- 2. config
say "2/5 write $CFG"
mkdir -p "$CFG_DIR"
if [ -f "$CFG" ]; then
  cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  ok "backed up existing config"
fi
TMPCFG="$(mktemp "$CFG_DIR/.opencode.jsonc.XXXXXX")"
cat > "$TMPCFG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "sk-hynix": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "SK hynix",
      "options": {
        "baseURL": "${BASE_URL}",
        "apiKey": "EMPTY",
        "timeout": 600000,
        "chunkTimeout": 60000
      },
      "models": {
        "${MODEL_ID}": {
          "name": "${MODEL_ID}",
          "limit": { "context": 262144, "input": 253952, "output": 8192 }
        }
      }
    }
  },
  "model": "sk-hynix/${MODEL_ID}",
  "small_model": "sk-hynix/${MODEL_ID}"
}
EOF
chmod 0600 "$TMPCFG"
mv -f "$TMPCFG" "$CFG"
ok "config written (model sk-hynix/${MODEL_ID} @ ${BASE_URL})"

[ "$CONFIG_ONLY" -eq 1 ] && { say "done (config only)"; exit 0; }

# ---------------------------------------------------------------- 3. server
say "3/5 check server ${BASE_URL}"
MODELS_JSON="$(curl -fsS --max-time 10 "${BASE_URL}/models" 2>/dev/null)" \
  || fail "server not reachable from this machine. On X3 run: x3-llm-service health"
echo "$MODELS_JSON" | grep -q "\"id\":\"${MODEL_ID}\"" \
  || fail "server is up but does not serve ${MODEL_ID}. Served ids: $(echo "$MODELS_JSON" | grep -o '"id":"[^"]*"' | tr '\n' ' ')"
ok "server serves ${MODEL_ID}"

# ---------------------------------------------------------------- 4. chat
say "4/5 chat smoke test"
REPLY="$(curl -fsS --max-time 180 "${BASE_URL}/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Answer with exactly: OK\"}],\"temperature\":0,\"max_tokens\":16}" \
  | grep -o '"content":"[^"]*"' | head -1)"
[ -n "$REPLY" ] || fail "chat request returned no content"
ok "model replied $REPLY"

# ---------------------------------------------------------------- 5. tools
say "5/5 tool-call smoke test (what the agent relies on)"
TOOLRESP="$(curl -fsS --max-time 180 "${BASE_URL}/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Call read_file on /tmp/example.txt.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read one file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}],\"tool_choice\":\"auto\",\"temperature\":0,\"max_tokens\":256}")"
if echo "$TOOLRESP" | grep -q '"tool_calls"' && echo "$TOOLRESP" | grep -q '"finish_reason":"tool_calls"'; then
  ok "structured tool_calls returned"
else
  echo "    WARNING: no structured tool_calls; agent may still work but check the server's --tool-call-parser" >&2
fi

# ---------------------------------------------------------------- done
say "all set"
cat <<EOF
    Open a new shell (or run: export PATH="\$HOME/.opencode/bin:\$PATH"), then:

        cd /path/to/your/project
        opencode

    Inside opencode:  /models  -> confirm sk-hynix/${MODEL_ID}
                      /init    -> let it write AGENTS.md for the project
                      Tab      -> switch plan / build mode
EOF
