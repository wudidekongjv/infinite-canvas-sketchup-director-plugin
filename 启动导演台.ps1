# 一键启动导演台（带 SU 同步参数）
# 用法：右键 → 使用 PowerShell 运行；或在终端执行  .\启动导演台.ps1
$ErrorActionPreference = 'Stop'

$desk   = Join-Path $PSScriptRoot '3d-director-desk-su'
$port   = 5199
$bridge = 'http://127.0.0.1:37740'

if (-not (Test-Path -LiteralPath (Join-Path $desk 'dist\index.html'))) {
  Write-Host "还没构建过导演台，正在构建……"
  Push-Location -LiteralPath $desk
  npm run build
  Pop-Location
}

Start-Job -ScriptBlock {
  param($d, $p)
  Set-Location -LiteralPath $d
  npx vite preview --port $p --strictPort
} -ArgumentList $desk, $port | Out-Null

Start-Sleep -Seconds 3
$url = "http://127.0.0.1:$port/?suBridge=$bridge"
Start-Process $url
Write-Host ""
Write-Host "导演台已启动：$url"
Write-Host "把这个地址填进你在用的画布/浏览器即可；SU 面板里记得先点“启动服务”。"
Write-Host "结束服务：本窗口关掉，或另开终端执行  Get-Job | Stop-Job"
