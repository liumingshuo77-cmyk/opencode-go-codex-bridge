#!/usr/bin/env bash
# back-to-chatgpt.sh - 把 codex 模型切回 gpt-5.6-sol (macOS 版)
# 对应 Windows 版 back-to-chatgpt.ps1 / back-to-chatgpt.bat
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source ./common.sh

step "切换 codex 模型回 $CHATGPT_MODEL"
if [ ! -f "$CODEX_CONFIG" ]; then
    err "codex config 不存在: $CODEX_CONFIG"
    exit 1
fi
backup_codex_files >/dev/null
set_codex_model "$CHATGPT_MODEL" --remove

echo ""
printf "\033[32m完成!Codex 已切回 %s。\033[0m\n" "$CHATGPT_MODEL"
printf "\033[90mopencode-go provider 配置已保留,随时可用 ./go-to-codex.sh 切回 DeepSeek V4 Pro\033[0m\n"
