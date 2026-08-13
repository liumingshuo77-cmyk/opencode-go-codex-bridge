#!/usr/bin/env bash
# go-to-codex.sh - 一键把 opencode go 订阅的 deepseek-v4-pro 配置到 codex 并切换 (macOS 版)
# 对应 Windows 版 go-to-codex.ps1 / go-to-codex.bat
# 用法: ./go-to-codex.sh [--setup]  (--setup 表示自动获取/重新配置 API key)
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source ./common.sh

timestamp=""
try_restore() {
    if [ -n "$timestamp" ] && [ -f "$CODEX_CONFIG.bak-$timestamp" ]; then
        step "验证/写入失败,自动回滚"
        restore_codex_files "$timestamp"
    fi
}

main() {
    local key

    step "1/6 读取 opencode go 订阅的 API key"
    if ! key=$(get_opencode_go_key "${1:-}"); then
        exit 1
    fi
    ok "key 已找到"

    step "2/6 验证订阅端点($UPSTREAM_BASE)"
    if ! test_go_endpoint "$key" >/dev/null; then
        exit 1
    fi
    ok "端点可用,模型 $UPSTREAM_MODEL_ID 在订阅中"

    step "3/6 启动 Responses->Chat 转换代理(deepseek-v4-pro 走 chat/completions)"
    if ! start_ogproxy "$key"; then
        exit 1
    fi

    step "4/6 备份 codex 配置"
    timestamp=$(backup_codex_files)

    step "5/6 写入 codex 配置(config.toml)"
    set_codex_model "$CODEX_MODEL_ID" "$PROVIDER_ID" || { try_restore; exit 1; }
    ensure_codex_provider_table "$PROVIDER_ID" "$PROVIDER_NAME" "$PROVIDER_BASE" "$key" || { try_restore; exit 1; }
    remove_codex_model_catalog_ref

    step "6/6 用 codex CLI 发测试消息验证"
    if ! test_codex_model; then
        try_restore
        exit 1
    fi

    echo ""
    printf "\033[32m完成!Codex 已接入 %s (%s,经 %s 订阅)。\033[0m\n" "$UPSTREAM_MODEL_ID" "$MODEL_DISPLAY" "$PROVIDER_ID"
    printf "\033[90mcodex 侧模型名显示为 %s(仅为让 codex 注入工具,实际请求已改写为 DeepSeek V4 Pro)。\033[0m\n" "$CODEX_MODEL_ID"
    printf "\033[90m切换回 ChatGPT 请运行 ./back-to-chatgpt.sh\033[0m\n"
    if pgrep -x "ChatGPT" >/dev/null 2>&1; then
        echo ""
        printf "\033[33m注意:检测到 Codex 桌面应用正在运行。应用在启动时读取配置,且可能用旧内存状态覆盖配置。\033[0m\n"
        printf "\033[33m      请完全退出(菜单栏图标右键退出)后重新打开应用,才能加载新的 opencode-go 配置。\033[0m\n"
    fi
}

main "${1:-}"
