#!/usr/bin/env bash
# common.sh - opencode-go -> codex 同步工具的共享逻辑 (macOS 版)
# 对应 Windows 版 common.ps1 的移植

set -uo pipefail

CODEX_HOME="$HOME/.codex"
CODEX_CONFIG="$CODEX_HOME/config.toml"
CODEX_AUTH="$CODEX_HOME/auth.json"
OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"
PROVIDER_ID="opencode-go"
PROVIDER_NAME="OpenCode Go"
UPSTREAM_BASE="https://opencode.ai/zen/go/v1"
PROVIDER_BASE="http://127.0.0.1:8765/v1"
CODEX_MODEL_ID="gpt-5.6-sol"
UPSTREAM_MODEL_ID="deepseek-v4-pro"
MODEL_DISPLAY="DeepSeek V4 Pro"
MODEL_CATALOG_JSON="$CODEX_HOME/model-catalog.json"
CHATGPT_MODEL="gpt-5.6-sol"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_SCRIPT="$SCRIPT_DIR/ogproxy.py"
PROXY_PORT=8765
PROXY_PID_FILE="/tmp/ogproxy.pid"
PROXY_LOG="/tmp/ogproxy.log"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

step() { printf "\033[36m==> %s\033[0m\n" "$1"; }
ok()   { printf "\033[32m    OK: %s\033[0m\n" "$1"; }
warn() { printf "\033[33m    WARN: %s\033[0m\n" "$1"; }
err()  { printf "\033[31m    ERROR: %s\033[0m\n" "$1"; }

# ---------- key 读取/保存 ----------

# 用 python3 解析 auth.json(兼容无 jq 的环境)
get_opencode_go_key() {
    if [ -f "$OPENCODE_AUTH" ]; then
        local key
        key=$(python3 -c "
import json
try:
    with open('$OPENCODE_AUTH') as f:
        auth = json.load(f)
    print(auth.get('$PROVIDER_ID', {}).get('key', ''))
except Exception:
    print('')
")
        if [ -n "$key" ]; then
            echo "$key"
            return 0
        fi
    fi
    if [ "${1:-}" = "setup" ]; then
        invoke_key_setup
        return $?
    fi
    err "在 $OPENCODE_AUTH 中找不到 provider '$PROVIDER_ID' 的 key。"
    err "请先运行 opencode 并执行 /connect 添加 OpenCode Go,或使用 -setup 一键获取。"
    return 1
}

save_opencode_go_key() {
    local key="$1"
    python3 -c "
import json, os
p = '$OPENCODE_AUTH'
os.makedirs(os.path.dirname(p), exist_ok=True)
auth = {}
if os.path.exists(p):
    try:
        with open(p) as f:
            auth = json.load(f)
    except Exception:
        auth = {}
auth.setdefault('$PROVIDER_ID', {})['key'] = '$key'
with open(p, 'w') as f:
    json.dump(auth, f, ensure_ascii=False, indent=2)
"
    ok "key 已保存到 $OPENCODE_AUTH"
}

invoke_key_setup() {
    step "未找到 OpenCode Go 的 API key,开始一键获取"
    echo ""
    printf "\033[33m  1) 将为你打开登录页: https://opencode.ai/auth\033[0m\n"
    printf "\033[33m  2) 登录后,把页面上的 OpenCode Go API key(以 sk- 开头)复制下来\033[0m\n"
    printf "\033[33m  3) 回到本窗口粘贴 key,回车确认(输入 q 退出)\033[0m\n"
    echo ""
    (open "https://opencode.ai/auth" 2>/dev/null) || warn "自动打开浏览器失败,请手动访问 https://opencode.ai/auth"
    for _ in 1 2 3; do
        read -r -p "请粘贴 OpenCode Go API key: " key
        key=$(echo "$key" | tr -d '[:space:]')
        if [ -z "$key" ] || [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            err "已取消获取 key。"
            return 1
        fi
        step "验证 key 有效性..."
        if curl -sf --max-time 30 -H "Authorization: Bearer $key" -H "User-Agent: $UA" "$UPSTREAM_BASE/models" >/dev/null; then
            save_opencode_go_key "$key"
            ok "key 验证通过"
            echo "$key"
            return 0
        else
            err "key 验证失败,请确认复制的是 OpenCode Go 的 key(以 sk- 开头),重新粘贴"
        fi
    done
    err "多次验证失败,已停止。请确认订阅已开通后再试。"
    return 1
}

# ---------- 上游验证 ----------

test_go_endpoint() {
    local key="$1" r
    r=$(curl -s --max-time 30 -H "Authorization: Bearer $key" "$UPSTREAM_BASE/models")
    if [ $? -ne 0 ] || [ -z "$r" ]; then
        err "无法访问 $UPSTREAM_BASE"
        return 1
    fi
    if echo "$r" | jq -r '.data[].id' 2>/dev/null | grep -qx "$UPSTREAM_MODEL_ID"; then
        echo "$r"
        return 0
    fi
    local ids
    ids=$(echo "$r" | jq -r '.data[].id' 2>/dev/null | tr '\n' ', ')
    err "订阅里没有模型 '$UPSTREAM_MODEL_ID'。可用: $ids"
    return 1
}

# ---------- codex 配置备份/恢复 ----------

backup_codex_files() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    if [ -f "$CODEX_CONFIG" ]; then
        cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$ts"
        ok "已备份: $CODEX_CONFIG.bak-$ts"
    fi
    echo "$ts"
}

restore_codex_files() {
    local ts="$1"
    if [ -f "$CODEX_CONFIG.bak-$ts" ]; then
        cp "$CODEX_CONFIG.bak-$ts" "$CODEX_CONFIG"
        warn "已恢复: $CODEX_CONFIG"
    fi
}

# ---------- config.toml 编辑(内嵌 python3,逻辑对齐 common.ps1) ----------

# 1. 更新 model 行 / 设置或移除 model_provider 行
set_codex_model() {
    local model_value="$1" model_provider="" remove_provider=0
    if [ "${2:-}" = "--remove" ]; then
        remove_provider=1
    elif [ -n "${2:-}" ]; then
        model_provider="$2"
    fi
    python3 -c "
import re, sys, os
p = '$CODEX_CONFIG'
if not os.path.exists(p):
    print('ERROR: codex config 不存在: %s' % p, file=sys.stderr)
    sys.exit(1)
with open(p, encoding='utf-8') as f:
    text = f.read()

# 1. model 行:替换或插入文件头部
if re.search(r'(?m)^model\s*=\s*[^\r\n]*', text):
    text = re.sub(r'(?m)^model\s*=\s*[^\r\n]*', 'model = \"$model_value\"', text, count=1)
else:
    text = 'model = \"$model_value\"\n' + text

# 2. model_provider 行:设置 / 移除 / 不动
remove_provider = $remove_provider
provider = '$model_provider'
if remove_provider:
    text = re.sub(r'(?m)^model_provider\s*=.*\r?\n', '', text)
    print('    OK: 已移除 model_provider 行(恢复默认 openai)', file=sys.stderr)
elif provider:
    if re.search(r'(?m)^model_provider\s*=.*', text):
        text = re.sub(r'(?m)^model_provider\s*=\s*[^\r\n]*', 'model_provider = \"%s\"' % provider, text, count=1)
    else:
        probe = 'model = \"$model_value\"'
        idx = text.find(probe)
        if idx < 0:
            idx = 0
        ins = idx + len(probe)
        if text[ins:ins + 1] == '\n':
            ins += 1
        text = text[:ins] + 'model_provider = \"%s\"\n' % provider + text[ins:]
    print('    OK: model_provider = %s' % provider, file=sys.stderr)

with open(p, 'w', encoding='utf-8') as f:
    f.write(text)
print('    OK: config.toml 已写入(model = $model_value)', file=sys.stderr)
"
}

# 2. 写入/更新 [model_providers.<id>] 表
ensure_codex_provider_table() {
    local pid="$1" pname="$2" base_url="$3" bearer="$4"
    python3 -c "
import re, sys, os
p = '$CODEX_CONFIG'
if not os.path.exists(p):
    print('ERROR: codex config 不存在: %s' % p, file=sys.stderr)
    sys.exit(1)
with open(p, encoding='utf-8') as f:
    text = f.read()

# 移除旧数组形式 model_providers = [ ... ]
text = re.sub(r'(?m)^model_providers\s*=.*\r?\n', '', text)

table = '[model_providers.$pid]\n' \
        'name = \"$pname\"\n' \
        'base_url = \"$base_url\"\n' \
        'wire_api = \"responses\"\n' \
        'experimental_bearer_token = \"$bearer\"'

header = '[model_providers.$pid]'
h = text.find(header)
if h >= 0:
    after = h + len(header)
    end = len(text)
    m = re.search(r'(?m)^\[[^\]]*\]\s*\$', text[after:])
    if m:
        end = after + m.start()
    text = text[:h] + table + text[end:]
    print('    OK: 已更新 [model_providers.$pid] 配置', file=sys.stderr)
else:
    text = text.rstrip('\n') + '\n\n' + table + '\n'
    print('    OK: 已新增 [model_providers.$pid] 配置', file=sys.stderr)

with open(p, 'w', encoding='utf-8') as f:
    f.write(text)
"
}

# 3. 移除 model_catalog_json 引用
remove_codex_model_catalog_ref() {
    python3 -c "
import re, sys, os
p = '$CODEX_CONFIG'
if not os.path.exists(p):
    sys.exit(0)
with open(p, encoding='utf-8') as f:
    text = f.read()
new_text = re.sub(r'(?m)^model_catalog_json\s*=.*\r?\n', '', text)
if new_text != text:
    with open(p, 'w', encoding='utf-8') as f:
        f.write(new_text)
    print('    OK: 已移除 model_catalog_json 引用(避免干扰已知模型解析)', file=sys.stderr)
"
}

# ---------- 代理启动 ----------

start_ogproxy() {
    local key="$1"
    local uri="http://127.0.0.1:$PROXY_PORT/v1/models"
    if curl -sf --max-time 3 "$uri" >/dev/null 2>&1; then
        ok "转换代理已在运行(端口 $PROXY_PORT)"
        return 0
    fi
    if [ ! -f "$PROXY_SCRIPT" ]; then
        err "找不到代理脚本: $PROXY_SCRIPT"
        return 1
    fi
    OPENCODE_GO_API_KEY="$key" nohup python3 "$PROXY_SCRIPT" >>"$PROXY_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PROXY_PID_FILE"
    for _ in $(seq 1 20); do
        sleep 0.5
        if curl -sf --max-time 2 "$uri" >/dev/null 2>&1; then
            ok "转换代理已启动(pid $pid,端口 $PROXY_PORT)"
            return 0
        fi
    done
    err "转换代理启动失败,日志: $(tail -c 2000 "$PROXY_LOG" 2>/dev/null)"
    return 1
}

stop_ogproxy() {
    if [ -f "$PROXY_PID_FILE" ]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE")
        kill "$pid" 2>/dev/null && warn "已停止代理(pid $pid)"
        rm -f "$PROXY_PID_FILE"
    fi
}

# ---------- codex CLI ----------

find_codex_exe() {
    local cmd
    cmd=$(command -v codex 2>/dev/null)
    if [ -n "$cmd" ]; then
        echo "$cmd"
        return 0
    fi
    if [ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]; then
        echo "/Applications/ChatGPT.app/Contents/Resources/codex"
        return 0
    fi
    return 1
}

test_codex_model() {
    local exe
    exe=$(find_codex_exe) || { err "找不到 codex CLI"; return 1; }
    local out err_file
    out=$(mktemp)
    err_file=$(mktemp)
    ok "调用 codex CLI 验证: $exe"
    "$exe" exec --model "$CODEX_MODEL_ID" --skip-git-repo-check 'Reply with exactly: OK' >"$out" 2>"$err_file" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 180 ]; then
            kill -9 "$pid" 2>/dev/null
            rm -f "$out" "$err_file"
            err "codex 验证超时(180s)"
            return 1
        fi
    done
    wait "$pid"
    local code=$?
    local out_text err_text
    out_text=$(cat "$out")
    err_text=$(cat "$err_file")
    rm -f "$out" "$err_file"
    # codex 可能因刷新模型元数据失败而退出码非零,但只要实际拿到回复就算通过
    if echo "$out_text" | grep -qE '^OK\s*$'; then
        if [ "$code" -ne 0 ]; then
            warn "codex 退出码为 $code(模型元数据刷新警告,不影响使用)"
        fi
        if ! { echo "$out_text$err_text" | grep -q "provider:\s*$PROVIDER_ID"; }; then
            warn "输出未包含 provider 标识,建议检查 config.toml 中 model_provider 设置"
        fi
        ok "codex 已成功用 $CODEX_MODEL_ID 回复"
        return 0
    fi
    if [ "$code" -ne 0 ]; then
        err "codex 验证失败(exit $code): $err_text $out_text"
        return 1
    fi
    warn "codex 退出码为 0 但输出异常: $out_text"
    return 1
}
