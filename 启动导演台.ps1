# 一键启动 SU 同步导演台（用仓库自带的 director/ 静态产物）
# 用法：在仓库根目录执行  .\启动导演台.ps1
$ErrorActionPreference = 'Stop'

$desk   = Join-Path $PSScriptRoot 'director'
$port   = 5199
$bridge = 'http://127.0.0.1:37740'

if (-not (Test-Path -LiteralPath (Join-Path $desk 'index.html'))) {
    Write-Host "找不到 director\index.html，请确认脚本放在仓库根目录。"
    exit 1
}

Write-Host "正在启动静态服务（首次会自动下载 http-server，需要几秒）…"
Start-Job -ScriptBlock {
    param($d, $p)
    Set-Location -LiteralPath $d
    npx --yes http-server . -p $p --cors -c-1
} -ArgumentList $desk, $port | Out-Null

Start-Sleep -Seconds 5
$url = "http://127.0.0.1:$port/?suBridge=$bridge"
Start-Process $url
Write-Host ""
Write-Host "导演台已启动：$url"
Write-Host "把这个地址填进画布节点面板的「导演台地址」；SU 面板里先点“启动服务”。"
Write-Host "停止服务：Get-Job | Stop-Job  （或关掉本窗口）"
