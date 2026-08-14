# switch-model.ps1 - 一键切换 codex 使用的 opencode-go 订阅模型(deepseek-v4-flash / kimi-k3 / glm-5.2 / gpt-5.6-luna 等)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Stop"

try {
    Write-Step "1/4 读取订阅模型列表"
    $key = Get-OpenCodeGoKey -AllowSetup
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    $r = Invoke-RestMethod -Uri "$($Script:UpstreamBaseUrl)/models" -Headers @{ Authorization = "Bearer $key"; "User-Agent" = $ua } -TimeoutSec 30
    $ids = @($r.data | ForEach-Object { $_.id })
    if ($ids.Count -eq 0) { throw "订阅模型列表为空" }
    Write-Ok "共 $($ids.Count) 个模型可用"

    Write-Step "2/4 选择模型"
    $current = (Get-OgProxyConfig).upstream_model
    Write-Host ""
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $mark = if ($ids[$i] -eq $current) { "  <-- 当前" } else { "" }
        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $ids[$i], $mark)
    }
    Write-Host ""
    $choice = Read-Host "输入序号选择模型(直接回车 = 保持当前,输入 q 退出)"
    if ($choice -eq "q" -or $choice -eq "Q") { throw "已取消" }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        Write-Ok "保持当前模型: $current"
        $model = $current
    } else {
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $ids.Count) { throw "无效序号: $choice" }
        $model = $ids[$idx]
    }

    # 显示名:优先从 opencode 缓存取友好名,取不到就用模型 id
    $display = $model
    try {
        $cache = Get-Content (Join-Path $env:USERPROFILE ".cache\opencode\models.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        foreach ($prov in $cache.PSObject.Properties) {
            if ($prov.Value -is [PSCustomObject] -and $prov.Value.models) {
                $m = $prov.Value.models.PSObject.Properties[$model]
                if ($m -and $m.Value.name) { $display = $m.Value.name; break }
            }
        }
    } catch {}

    Write-Step "3/4 切换模型(热切换,无需重启)"
    Set-OgProxyConfig -UpstreamModel $model -DisplayName $display
    if (-not (Invoke-OgProxyHotSwitch -UpstreamModel $model -DisplayName $display)) {
        # 代理没在运行:先保存配置,再由 go-to-codex 流程启动;这里直接尝试拉起
        try {
            $probe = Invoke-RestMethod -Uri "http://127.0.0.1:$($Script:ProxyPort)/v1/models" -TimeoutSec 3
        } catch {
            Start-OgProxy -Key $key
            $null = Invoke-OgProxyHotSwitch -UpstreamModel $model -DisplayName $display
        }
    }
    Update-CodexModelsCache

    Write-Step "4/4 验证模型可用"
    $body = @{ model = $Script:CodexModelId; input = "Reply with exactly: OK"; stream = $false } | ConvertTo-Json
    try {
        $r2 = Invoke-RestMethod -Uri "http://127.0.0.1:$($Script:ProxyPort)/v1/responses" -Method Post -Headers @{ "Content-Type" = "application/json" } -Body $body -TimeoutSec 120
        $text = ($r2.output | Where-Object { $_.type -eq "message" } | ForEach-Object { ($_.content | ForEach-Object { $_.text }) -join "" }) -join ""
        if ($text -notmatch "OK") { Write-Warn "验证回复异常: $text" } else { Write-Ok "验证通过" }
    } catch {
        Write-Warn "验证调用失败(不影响切换,代理可能仍在启动): $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "完成!当前使用模型: $model ($display)" -ForegroundColor Green
    Write-Host "已热切换,无需重启 Codex。新开聊天即可生效;应用模型选择器约 3 分钟内同步显示。" -ForegroundColor DarkGray
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
