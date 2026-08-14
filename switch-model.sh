#!/usr/bin/env bash
# switch-model.sh - 一键切换 codex 使用的 opencode-go 订阅模型 (macOS 版)
# 对应 Windows 版 switch-model.ps1 / switch-model.bat
# 用法: ./switch-model.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source ./common.sh

main() {
    step "1/4 读取订阅模型列表"
    local key
    if ! key=$(get_opencode_go_key setup); then
        exit 1
    fi
    local r
    r=$(curl -s --max-time 30 -H "Authorization: Bearer $key" -H "User-Agent: $UA" "$UPSTREAM_BASE/models") || { err "获取模型列表失败"; exit 1; }
    local ids
    ids=$(echo "$r" | python3 -c "
import json, sys
try:
    print('\n'.join(m['id'] for m in json.load(sys.stdin).get('data', [])))
except Exception:
    sys.exit(1)
") || { err "解析模型列表失败"; exit 1; }
    local count
    count=$(echo "$ids" | grep -c .)
    ok "共 $count 个模型可用"

    step "2/4 选择模型"
    local cur
    cur=$(get_ogproxy_config | cut -d'|' -f1)
    echo ""
    local i=1 line mark
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        mark=""
        [ "$line" = "$cur" ] && mark="  <-- 当前"
        printf "  %2d. %s%s\n" "$i" "$line" "$mark"
        i=$((i + 1))
    done <<< "$ids"
    echo ""
    local choice model
    read -r -p "输入序号选择模型(直接回车 = 保持当前,输入 q 退出): " choice
    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        err "已取消"
        exit 1
    fi
    if [ -z "$choice" ]; then
        model="$cur"
        ok "保持当前模型: $model"
    else
        case "$choice" in
            *[!0-9]*)
                err "无效序号: $choice"
                exit 1
                ;;
        esac
        model=$(echo "$ids" | sed -n "${choice}p")
        [ -z "$model" ] && { err "无效序号: $choice"; exit 1; }
    fi

    # 显示名:优先从 opencode 缓存取友好名,取不到就用模型 id
    local disp="$model" name
    if [ -f "$HOME/.cache/opencode/models.json" ]; then
        name=$(python3 -c "
import json
try:
    with open('$HOME/.cache/opencode/models.json') as f:
        data = json.load(f)
    for prov in data.values():
        if isinstance(prov, dict) and isinstance(prov.get('models'), dict):
            m = prov['models'].get('$model')
            if m and m.get('name'):
                print(m['name'])
                break
except Exception:
    pass
")
        [ -n "$name" ] && disp="$name"
    fi

    step "3/4 切换模型(热切换,无需重启)"
    set_ogproxy_config "$model" "$disp"
    if ! hot_switch_ogproxy "$model" "$disp"; then
        # 代理没在运行:先拉起,再热切换
        if ! start_ogproxy "$key"; then
            exit 1
        fi
        hot_switch_ogproxy "$model" "$disp" || true
    fi
    sync_models_cache

    step "4/4 验证模型可用"
    local resp text
    resp=$(curl -s --max-time 120 -X POST "http://127.0.0.1:$PROXY_PORT/v1/responses" \
        -H "Content-Type: application/json" \
        -d '{"model": "'"$CODEX_MODEL_ID"'", "input": "Reply with exactly: OK", "stream": false}') || true
    text=$(echo "$resp" | python3 -c "
import json, sys
try:
    out = json.load(sys.stdin).get('output', [])
    print(''.join(c.get('text', '') for it in out if it.get('type') == 'message' for c in it.get('content', []) if isinstance(c, dict)))
except Exception:
    print('')
")
    if echo "$text" | grep -q "OK"; then
        ok "验证通过"
    else
        warn "验证回复异常: ${text:0:80}"
    fi

    echo ""
    printf "\033[32m完成!当前使用模型: %s (%s)\033[0m\n" "$model" "$disp"
    printf "\033[90m已热切换,无需重启 Codex。新开聊天即可生效;应用模型选择器约 3 分钟内同步显示。\033[0m\n"
    printf "\033[90m也可以在应用模型选择器里直接挑选订阅模型(DeepSeek V4 Pro/Flash、Kimi K3、GLM-5.2 等)。\033[0m\n"
}

main "$@"
