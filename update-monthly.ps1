# AI 工具 TOP100 —— 每月更新（GitHub Actions 每月第一次执行时跑；平常会自动跳过）
# 汇率：open.er-api.com 公开汇率，免费、不需要金钥。网页上的台币价格依这个汇率换算。
param([switch]$Force)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'index.html'
$logFile = Join-Path $here 'update.log'
$utf8 = New-Object Text.UTF8Encoding $false

$tz = $null
foreach ($id in 'Asia/Taipei', 'Taipei Standard Time') { try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
$now = if ($tz) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::UtcNow.AddHours(8) }
$month = $now.ToString('yyyy-MM')
function Write-Log($msg) {
  $line = $now.ToString('yyyy-MM-dd HH:mm') + '  [每月] ' + $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

$tag = '<script type="application/json" id="price-tiers">'
$html = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$a = $html.IndexOf($tag); if ($a -lt 0) { throw '网页里找不到 price-tiers 资料区块' }
$a += $tag.Length; $b = $html.IndexOf('</script>', $a)
$pr = $html.Substring($a, $b - $a).Replace('<\/', '</') | ConvertFrom-Json
if (-not $Force -and $pr.fxDate -eq $month) { Write-Host "本月（$month）汇率已经更新过，跳过"; exit 0 }

try {
  $fx = Invoke-RestMethod 'https://open.er-api.com/v6/latest/USD' -TimeoutSec 30
  if ($fx.result -ne 'success' -or $fx.rates.TWD -lt 20 -or $fx.rates.TWD -gt 50) { throw '汇率资料不正常' }
  $twd = [double]$fx.rates.TWD
  $pr.fx.USD = [Math]::Round($twd, 2)
  $pr.fx.EUR = [Math]::Round($twd / [double]$fx.rates.EUR, 2)
  $pr.fx.CNY = [Math]::Round($twd / [double]$fx.rates.CNY, 2)
  $pr.fxDate = $month
  # 所有 < 都写成 <，资料里就算出现 </script> 也拆不开网页
  $lt = [string][char]92 + 'u003c'
  [IO.File]::WriteAllText($target, $html.Substring(0, $a) + ($pr | ConvertTo-Json -Depth 20 -Compress).Replace('<', $lt) + $html.Substring($b), $utf8)
  Write-Log "汇率已更新：1 USD = $($pr.fx.USD) TWD、1 EUR = $($pr.fx.EUR)、1 CNY = $($pr.fx.CNY)"
} catch {
  Write-Log "汇率更新失败，保留原值（$($_.Exception.Message)）"
  exit 1
}
