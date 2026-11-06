# 一键启动 SU 同步导演台（用仓库自带的 director/ 静态产物，不联网、不装任何东西）
# 用法：双击本文件，或在仓库根目录执行  pwsh -File .\启动导演台.ps1
$ErrorActionPreference = 'Stop'

$root   = $PSScriptRoot
$port   = 5199
$bridge = 'http://127.0.0.1:37740'
$server = Join-Path $root 'tools\serve-director.mjs'

if (-not (Test-Path -LiteralPath $server)) {
    Write-Host "找不到 tools\serve-director.mjs，请确认脚本放在仓库根目录。"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'director\index.html'))) {
    Write-Host "找不到 director\index.html，请确认仓库目录完整。"
    exit 1
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    Write-Host "没找到 node，请先安装 Node.js（本机 node 通常已在 PATH 里）。"
    exit 1
}

# 端口已在监听就不再重复起
$already = $null
try { $already = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop } catch { }
if ($already) {
    Write-Host "端口 $port 已有服务在跑，直接打开页面。"
} else {
    Start-Process -FilePath $node -ArgumentList @($server, "$port") -WorkingDirectory $root -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $check = $null
    try { $check = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop } catch { }
    if (-not $check) {
        Write-Host "静态服务没起来，请把下面这条命令在仓库根目录跑一遍看报错："
        Write-Host "  node tools\serve-director.mjs 5199"
        exit 1
    }
}

# SU 侧的服务只能由 SketchUp 进程自己起，这里只做提示
$suUp = $null
try { $suUp = Get-NetTCPConnection -LocalPort 37740 -State Listen -ErrorAction Stop } catch { }

Start-Process "http://127.0.0.1:$port/?suBridge=$bridge"
Write-Host ""
Write-Host "导演台已启动：http://127.0.0.1:$port/"
Write-Host "把这个地址填进画布节点面板的「导演台地址」。" 
if ($suUp) {
    Write-Host "SketchUp 侧 37740 已在监听，可以开始同步。"
} else {
    Write-Host "注意：SketchUp 侧 37740 还没起。请在 SketchUp 里打开插件面板，点「启动服务」，再回来刷页面。" 
}
Write-Host "停止静态服务：Stop-Process -Id (Get-NetTCPConnection -LocalPort $port -State Listen).OwningProcess"
