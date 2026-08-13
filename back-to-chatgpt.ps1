# back-to-chatgpt.ps1 - 把 codex 模型切回 gpt-5.6-sol(保留 opencode-go provider 配置)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

try {
    Write-Step "切换 codex 模型回 $($Script:ChatGptModel)"
    if (-not (Test-Path $Script:CodexConfigPath)) {
        throw "codex config 不存在: $($Script:CodexConfigPath)"
    }
    $timestamp = Backup-CodexFiles
    Set-CodexModel -ModelValue $Script:ChatGptModel -RemoveModelProvider

    Write-Host ""
    Write-Host "完成!Codex 已切回 $($Script:ChatGptModel)。" -ForegroundColor Green
    Write-Host "opencode-go provider 配置已保留,随时可用 go-to-codex.bat 切回 DeepSeek V4 Flash" -ForegroundColor DarkGray
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
