# go-to-codex.ps1 - 一键把 opencode go 订阅的 deepseek-v4-pro 配置到 codex 并切换
# 原理:codex 只给"已知模型名"注入工具,所以 codex 侧使用 gpt-5.6-sol 的模型名,
#       本地转换代理把请求改写为 deepseek-v4-pro 发送到 opencode-go 上游。
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"
$timestamp = $null

try {
    Write-Step "1/6 读取 opencode go 订阅的 API key"
    $key = Get-OpenCodeGoKey -AllowSetup
    Write-Ok "key 已找到"

    Write-Step "2/6 验证订阅端点($($Script:UpstreamBaseUrl))"
    $null = Test-GoEndpoint -Key $key
    Write-Ok "端点可用,模型 $($Script:UpstreamModelId) 在订阅中"

    Write-Step "3/6 启动 Responses->Chat 转换代理(deepseek-v4-pro 走 chat/completions)"
    Start-OgProxy -Key $key

    Write-Step "4/6 备份 codex 配置"
    $timestamp = Backup-CodexFiles

    Write-Step "5/6 写入 codex 配置(config.toml)"
    Set-CodexModel -ModelValue $Script:CodexModelId -ModelProvider $Script:ProviderId
    Ensure-CodexProviderTable -ProviderId $Script:ProviderId -ProviderName $Script:ProviderName -BaseUrl $Script:ProviderBaseUrl -BearerToken $key
    Remove-CodexModelCatalogRef

    Write-Step "6/6 用 codex CLI 发测试消息验证"
    Test-CodexModel

    Write-Host ""
    Write-Host "完成!Codex 已接入 $($Script:UpstreamModelId) ($($Script:ModelDisplayName),经 $($Script:ProviderId) 订阅)。" -ForegroundColor Green
    Write-Host "codex 侧模型名显示为 gpt-5.6-sol(仅为让 codex 注入工具,实际请求已改写为 DeepSeek V4 Pro)。" -ForegroundColor DarkGray
    Write-Host "切换回 ChatGPT 请运行 back-to-chatgpt.bat" -ForegroundColor DarkGray
    $running = Get-Process -Name "codex" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host ""
        Write-Host "注意:检测到 Codex 桌面应用正在运行。应用在启动时读取配置,且可能用旧内存状态覆盖配置。" -ForegroundColor Yellow
        Write-Host "      请完全退出(托盘图标右键退出)后重新打开应用,才能加载新的 opencode-go 配置。" -ForegroundColor Yellow
    }
} catch {
    Write-Err $_.Exception.Message
    if ($timestamp) {
        Write-Step "验证/写入失败,自动回滚"
        Restore-CodexFiles -Timestamp $timestamp
    }
    exit 1
}
