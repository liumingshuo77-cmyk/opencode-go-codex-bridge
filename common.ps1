# common.ps1 - opencode-go -> codex 同步工具的共享逻辑
$ErrorActionPreference = "Stop"

$Script:CodexHome        = Join-Path $env:USERPROFILE ".codex"
$Script:CodexConfigPath  = Join-Path $Script:CodexHome "config.toml"
$Script:CodexAuthPath    = Join-Path $Script:CodexHome "auth.json"
$Script:OpenCodeAuthPath = Join-Path $env:USERPROFILE ".local\share\opencode\auth.json"
$Script:ProviderId       = "opencode-go"
$Script:ProviderName     = "OpenCode Go"
$Script:UpstreamBaseUrl  = "https://opencode.ai/zen/go/v1"
$Script:ProviderBaseUrl  = "http://127.0.0.1:8765/v1"
$Script:CodexModelId     = "gpt-5.6-sol"
$Script:UpstreamModelId  = "deepseek-v4-pro"
$Script:ModelDisplayName = "DeepSeek V4 Pro"
$Script:ModelCatalogJson = Join-Path $Script:CodexHome "model-catalog.json"
$Script:ChatGptModel     = "gpt-5.6-sol"
$Script:ProxyScript      = Join-Path $PSScriptRoot "ogproxy.py"
$Script:ProxyConfigPath  = Join-Path $PSScriptRoot "ogproxy-config.json"
$Script:ProxyPort        = 8765

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    ERROR: $msg" -ForegroundColor Red }

function Get-OpenCodeGoKey {
    param([switch]$AllowSetup)
    $p = $Script:OpenCodeAuthPath
    if (Test-Path $p) {
        try {
            $auth = Get-Content $p -Raw | ConvertFrom-Json
            $prop = $auth.PSObject.Properties[$Script:ProviderId]
            if ($prop -and $prop.Value.key) {
                return $prop.Value.key
            }
        } catch {}
    }
    if ($AllowSetup) {
        return Invoke-KeySetup
    }
    throw "在 $p 中找不到 provider '$($Script:ProviderId)' 的 key。请先运行 /connect 添加 OpenCode Go,或使用 -AllowSetup 一键获取。"
}

function Save-OpenCodeGoKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    $p = $Script:OpenCodeAuthPath
    $dir = Split-Path $p -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $auth = [PSCustomObject]@{}
    if (Test-Path $p) {
        $auth = Get-Content $p -Raw | ConvertFrom-Json
    }
    $prop = $auth.PSObject.Properties[$Script:ProviderId]
    if ($prop -and $prop.Value -is [PSCustomObject]) {
        $prop.Value | Add-Member -NotePropertyName "key" -NotePropertyValue $Key -Force
    } else {
        $o = New-Object PSCustomObject
        $o | Add-Member -NotePropertyName "key" -NotePropertyValue $Key
        $auth | Add-Member -NotePropertyName $Script:ProviderId -NotePropertyValue $o -Force
    }
    $out = $auth | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($p, $out, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "key 已保存到 $p"
}

function Invoke-KeySetup {
    Write-Step "未找到 OpenCode Go 的 API key,开始一键获取"
    Write-Host ""
    Write-Host "  1) 将为你打开登录页: https://opencode.ai/auth" -ForegroundColor Yellow
    Write-Host "  2) 登录后,把页面上的 OpenCode Go API key(以 sk- 开头)复制下来" -ForegroundColor Yellow
    Write-Host "  3) 回到本窗口粘贴 key,回车确认(输入 q 退出)" -ForegroundColor Yellow
    Write-Host ""
    try {
        Start-Process "https://opencode.ai/auth"
    } catch {
        Write-Warn "自动打开浏览器失败,请手动访问 https://opencode.ai/auth"
    }
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $key = Read-Host "请粘贴 OpenCode Go API key"
        $key = $key.Trim()
        if ($key -eq "" -or $key -eq "q" -or $key -eq "Q") { throw "已取消获取 key。" }
        Write-Step "验证 key 有效性..."
        try {
            $r = Invoke-RestMethod -Uri "$($Script:UpstreamBaseUrl)/models" -Headers @{ Authorization = "Bearer $key"; "User-Agent" = $ua } -TimeoutSec 30
            $ids = @($r.data | ForEach-Object { $_.id })
            if ($ids -notcontains $Script:UpstreamModelId) {
                Write-Warn "key 有效,但订阅里没有模型 '$($Script:UpstreamModelId)'。可用: $($ids -join ', ')"
            }
            Save-OpenCodeGoKey -Key $key
            Write-Ok "key 验证通过"
            return $key
        } catch {
            Write-Err "key 验证失败: $($_.Exception.Message)"
            Write-Warn "请确认复制的是 OpenCode Go 的 key(以 sk- 开头),重新粘贴"
        }
    }
    throw "多次验证失败,已停止。请确认订阅已开通后再试。"
}

function Test-GoEndpoint {
    param([Parameter(Mandatory = $true)][string]$Key)
    try {
        $headers = @{ Authorization = "Bearer $Key" }
        $r = Invoke-RestMethod -Uri "$($Script:UpstreamBaseUrl)/models" -Headers $headers -TimeoutSec 30
        $ids = @($r.data | ForEach-Object { $_.id })
        if ($ids -notcontains $Script:UpstreamModelId) {
            throw "订阅里没有模型 '$($Script:UpstreamModelId)'。可用: $($ids -join ', ')"
        }
        return $ids
    } catch {
        if ($_.Exception.Message -match "401|403|unauthorized") {
            throw "API key 无效或未授权: $($_.Exception.Message)"
        }
        throw "无法访问 $($Script:UpstreamBaseUrl): $($_.Exception.Message)"
    }
}

function Backup-CodexFiles {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    if (Test-Path $Script:CodexConfigPath) {
        $bak = "$($Script:CodexConfigPath).bak-$ts"
        Copy-Item $Script:CodexConfigPath $bak -Force
        Write-Ok "已备份: $bak"
    }
    return $ts
}

function Restore-CodexFiles {
    param([Parameter(Mandatory = $true)][string]$Timestamp)
    $bak = "$($Script:CodexConfigPath).bak-$Timestamp"
    if (Test-Path $bak) {
        Copy-Item $bak $Script:CodexConfigPath -Force
        Write-Warn "已恢复: $Script:CodexConfigPath"
    }
}

# 读取 config.toml 并把行尾统一规范化为 CRLF(桌面应用会写成 LF,混合行尾会破坏插入逻辑)
function Read-ConfigText {
    return [regex]::Replace([System.IO.File]::ReadAllText($Script:CodexConfigPath), "(?<!`r)`n", "`r`n")
}

function Write-ConfigText {
    param([Parameter(Mandatory = $true)][string]$Text)
    [System.IO.File]::WriteAllText($Script:CodexConfigPath, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-CodexModel {
    param(
        [Parameter(Mandatory = $true)][string]$ModelValue,
        [string]$ModelProvider = $null,
        [switch]$RemoveModelProvider
    )
    if (-not (Test-Path $Script:CodexConfigPath)) {
        throw "codex config 不存在: $($Script:CodexConfigPath)"
    }
    $text = Read-ConfigText

    # 1. 更新 model 行(不存在则插入到文件头部)
    if ($text -match "(?m)^model\s*=\s*[^\r\n]*") {
        $text = [regex]::Replace($text, "(?m)^model\s*=\s*[^\r\n]*", "model = `"$ModelValue`"")
    } else {
        $text = "model = `"$ModelValue`"" + "`r`n" + $text
    }

    # 2. model_provider 行:设置 / 移除 / 不动
    if ($RemoveModelProvider) {
        $text = [regex]::Replace($text, "(?m)^model_provider\s*=.*\r?\n", "")
        Write-Ok "已移除 model_provider 行(恢复默认 openai)"
    } elseif ($ModelProvider) {
        if ($text -match "(?m)^model_provider\s*=.*") {
            $text = [regex]::Replace($text, "(?m)^model_provider\s*=\s*[^\r\n]*", "model_provider = `"$ModelProvider`"")
        } else {
            $probe = "model = `"$ModelValue`""
            $p = $text.IndexOf($probe)
            $lineEnd = $text.IndexOf("`r`n", $p)
            if ($lineEnd -lt 0) { $lineEnd = $text.Length }
            $ins = $lineEnd + 2
            $text = $text.Substring(0, $ins) + "model_provider = `"$ModelProvider`"" + "`r`n" + $text.Substring($ins)
        }
        Write-Ok "model_provider = $ModelProvider"
    }

    Write-ConfigText -Text $text
    Write-Ok "config.toml 已写入(model = $ModelValue)"
}

function Ensure-CodexProviderTable {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$ProviderName = $ProviderId,
        [string]$BaseUrl = $null,
        [string]$BearerToken = $null
    )
    if (-not (Test-Path $Script:CodexConfigPath)) {
        throw "codex config 不存在: $($Script:CodexConfigPath)"
    }
    $text = Read-ConfigText

    # 若存在旧的数组形式 model_providers = [ ... ] 行,先移除(新版 codex 要求 table 形式)
    $text = [regex]::Replace($text, "(?m)^model_providers\s*=.*\r?\n", "")

    # 此版本 codex 只认 config 内的 experimental_bearer_token(env_key 需要环境变量,桌面端拿不到)
    $tableText = "[model_providers.$ProviderId]" + "`r`n" +
                 "name = `"$ProviderName`"" + "`r`n" +
                 "base_url = `"$BaseUrl`"" + "`r`n" +
                 "wire_api = `"responses`"" + "`r`n" +
                 "experimental_bearer_token = `"$BearerToken`""

    $header = "[model_providers.$ProviderId]"
    $h = $text.IndexOf($header)
    if ($h -ge 0) {
        $after = $h + $header.Length
        $end = $text.Length
        $m = [regex]::Match($text.Substring($after), "(?m)^\[[^\]]*\]\s*$")
        if ($m.Success) { $end = $after + $m.Index }
        $text = $text.Substring(0, $h) + $tableText + $text.Substring($end)
        Write-Ok "已更新 [model_providers.$ProviderId] 配置"
    } else {
        $tail = $text.TrimEnd("`r", "`n")
        $text = $tail + "`r`n`r`n" + $tableText + "`r`n"
        Write-Ok "已新增 [model_providers.$ProviderId] 配置"
    }

    Write-ConfigText -Text $text
}

function Stop-OgProxy {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "ogproxy\.py" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}

function Get-OgProxyConfig {
    $cfg = @{ upstream_model = $Script:UpstreamModelId; display_name = $Script:ModelDisplayName; codex_model = "gpt-5.6-sol" }
    if (Test-Path $Script:ProxyConfigPath) {
        try {
            $saved = Get-Content $Script:ProxyConfigPath -Raw | ConvertFrom-Json
            if ($saved.upstream_model) { $cfg.upstream_model = $saved.upstream_model }
            if ($saved.display_name) { $cfg.display_name = $saved.display_name }
            if ($saved.codex_model) { $cfg.codex_model = $saved.codex_model }
        } catch {}
    }
    return $cfg
}

function Set-OgProxyConfig {
    param(
        [Parameter(Mandatory = $true)][string]$UpstreamModel,
        [string]$DisplayName = $UpstreamModel
    )
    $cfg = @{ upstream_model = $UpstreamModel; display_name = $DisplayName; codex_model = "gpt-5.6-sol" }
    $cfg | ConvertTo-Json | Set-Content $Script:ProxyConfigPath -Encoding UTF8
    Write-Ok "已保存模型配置: $UpstreamModel"
}

function Start-OgProxy {
    param([Parameter(Mandatory = $true)][string]$Key)
    $uri = "http://127.0.0.1:$($Script:ProxyPort)/v1/models"
    try {
        $null = Invoke-RestMethod -Uri $uri -TimeoutSec 3
        Write-Ok "转换代理已在运行(端口 $($Script:ProxyPort))"
        return
    } catch {}
    if (-not (Test-Path $Script:ProxyScript)) {
        throw "找不到代理脚本: $($Script:ProxyScript)"
    }
    $env:OPENCODE_GO_API_KEY = $Key
    $log = Join-Path $env:TEMP "ogproxy.log"
    $p = Start-Process -FilePath "python" -ArgumentList "`"$($Script:ProxyScript)`"" -WindowStyle Hidden -PassThru -RedirectStandardError $log
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $null = Invoke-RestMethod -Uri $uri -TimeoutSec 2
            Write-Ok "转换代理已启动(pid $($p.Id),端口 $($Script:ProxyPort))"
            return
        } catch {}
    }
    throw "转换代理启动失败,日志: $(Get-Content $log -Raw -ErrorAction SilentlyContinue)"
}

function Remove-CodexModelCatalogRef {
    # catalog 只给未知模型用;现在 codex 用已知模型名(gpt-5.6-sol)换取工具注入,必须移除 catalog 引用
    if (-not (Test-Path $Script:CodexConfigPath)) { return }
    $text = Read-ConfigText
    $newText = [regex]::Replace($text, "(?m)^model_catalog_json\s*=.*\r?\n", "")
    if ($newText -ne $text) {
        Write-ConfigText -Text $newText
        Write-Ok "已移除 model_catalog_json 引用(避免干扰已知模型解析)"
    }
}

function Find-CodexExe {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exes = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin") -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($exes.Count -gt 0) { return $exes[0].FullName }
    return $null
}

function Test-CodexModel {
    $exe = Find-CodexExe
    if (-not $exe) { throw "找不到 codex CLI" }
    $outFile = Join-Path $env:TEMP "codex-test-$PID.out"
    $errFile = Join-Path $env:TEMP "codex-test-$PID.err"
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    $model = $Script:CodexModelId
    $args = @("exec", "--model", $model, "--skip-git-repo-check", '"Reply with exactly: OK"')
    Write-Ok "调用 codex CLI 验证: $exe"
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit(180000)) {
        $p.Kill()
        throw "codex 验证超时(180s)"
    }
    $out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    $code = 0
    if ($null -ne $p.ExitCode) { $code = [int]$p.ExitCode }
    # codex 可能因刷新模型元数据失败(go 端点 /models 格式差异)而退出码非零,
    # 但只要实际拿到了回复,就算验证通过
    $replied = $out -match "(?m)^OK\s*$"
    if ($replied) {
        if ($code -ne 0) {
            Write-Warn "codex 退出码为 $code(模型元数据刷新警告,不影响使用)"
        }
        if (($out + $err) -notmatch "provider:\s+$($Script:ProviderId)") {
            Write-Warn "输出未包含 provider 标识,建议检查 config.toml 中 model_provider 设置"
        }
        Write-Ok "codex 已成功用 $model 回复"
        return
    }
    if ($code -ne 0) {
        throw "codex 验证失败(exit $code): $err $out"
    }
    Write-Warn "codex 退出码为 0 但输出异常: $out"
}
