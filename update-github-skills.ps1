# GitHub Skills 推荐 —— 云端自动更新脚本（GitHub Actions 版，跟榜单一起每 12 小时执行）
# 1. 抓 GitHub Trending（本周、全部语言共 25 页）→ 只收 AI 编程代理、技能与开发工具 → 依本周涨星取前十
# 2. 抓近 7 天新上线的 Skills（爆红），以及近 30 天的（前十不足时补上）
# 3. 更新 65 个精选 Skills 的 GitHub 星数
# 4. 不在精选里的项目，把 GitHub 英文介绍翻成中文（记住译文，原文没变就不再重翻）
# 结果写进 index.html 里的 gh-trend 资料区块，由 GitHub Actions 提交后，Cloudflare Pages 自动发布。
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'index.html'
$logFile = Join-Path $here 'update.log'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36'
$utf8 = New-Object Text.UTF8Encoding $false
$tag = '<script type="application/json" id="gh-trend">'

$tz = $null
foreach ($id in 'Asia/Taipei', 'Taipei Standard Time') { try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
$now = if ($tz) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::UtcNow.AddHours(8) }
function Write-Log($msg) {
  $line = $now.ToString('yyyy-MM-dd HH:mm') + '  [GitHub Skills] ' + $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}
$gh = @{ 'User-Agent' = 'ai-top100-updater'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $gh['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
function Get-Num($s) { if ($s) { [int]($s -replace ',', '') } else { 0 } }

# 收录标准：比照 UltraLab「只收 AI repo」的取向，聚焦 AI 编程代理、技能与开发工具
$aiRx = '\b(agents?|agentic|skills?|claude|codex|copilot|mcp|cursor|coding|code[- ]review|prompts?|anthropic|openai|gemini|vibe[- ]coding)\b|智能体|技能'
$langs = @('', 'python', 'typescript', 'javascript', 'shell', 'go', 'rust', 'html', 'markdown', 'jupyter-notebook', 'unknown', 'java',
  'c++', 'swift', 'vue', 'css', 'powershell', 'dockerfile', 'lua', 'c', 'kotlin', 'ruby', 'php', 'dart', 'zig')

function Get-Trending([string]$html) {
  $out = New-Object System.Collections.ArrayList
  $start = '<article class="Box-row">'
  $i = $html.IndexOf($start)
  while ($i -ge 0) {
    $e = $html.IndexOf('</article>', $i); if ($e -lt 0) { break }
    $b = $html.Substring($i, $e - $i); $i = $html.IndexOf($start, $e)
    $m = [regex]::Match($b, '<h2[\s\S]*?href="/([^"/?]+/[^"/?]+)"'); if (-not $m.Success) { continue }
    $repo = $m.Groups[1].Value
    $dm = [regex]::Match($b, '<p class="[^"]*col-9[^"]*"[^>]*>([\s\S]*?)</p>')
    $d = if ($dm.Success) { [Net.WebUtility]::HtmlDecode(([regex]::Replace($dm.Groups[1].Value, '<[^>]+>', '') -replace '\s+', ' ').Trim()) } else { '' }
    $gm = [regex]::Match($b, '([\d,]+)\s+stars?\s+this\s+week')
    $sm = [regex]::Match($b, 'href="/[^"]+/stargazers"[\s\S]*?</svg>\s*([\d,]+)\s*</a>')
    [void]$out.Add([pscustomobject]@{ repo = $repo; n = $repo.Split('/')[1]; d = $d; stars = (Get-Num $sm.Groups[1].Value); gain = (Get-Num $gm.Groups[1].Value); l = 'u' })
  }
  , $out
}

# ---------- 翻译：GitHub 原文介绍 → 简体中文（网页再依语言转繁体）。先用 MyMemory，失败改用 Google；都失败就保留原文 ----------
$script:trans = @{}      # repo → @{ s = 原文; z = 译文 }，存在页面资料里，下次原文没变就直接沿用
$script:transNew = 0
function Get-Zh([string]$repo, [string]$text) {
  if (-not $text) { return '' }
  if ($text -match '[一-鿿]') { return $text }      # 本来就是中文
  $k = $repo.ToLower()
  if ($script:trans.ContainsKey($k) -and $script:trans[$k].s -eq $text) { return $script:trans[$k].z }
  $src = if ($text.Length -gt 480) { $text.Substring(0, 480) } else { $text }
  $q = [uri]::EscapeDataString($src); $zh = ''
  try {
    $r = Invoke-RestMethod "https://api.mymemory.translated.net/get?q=$q&langpair=en|zh-CN" -TimeoutSec 20
    if ([int]$r.responseStatus -eq 200 -and $r.responseData.translatedText -notmatch 'MYMEMORY WARNING') { $zh = [Net.WebUtility]::HtmlDecode($r.responseData.translatedText) }
  } catch { }
  if (-not $zh) {
    try { $r = Invoke-RestMethod "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t&q=$q" -TimeoutSec 20; $zh = ($r[0] | ForEach-Object { $_[0] }) -join '' } catch { }
  }
  Start-Sleep -Milliseconds 300
  if ($zh -and $zh -match '[一-鿿]') { $script:trans[$k] = @{ s = $text; z = $zh }; $script:transNew++; return $zh }
  ''
}

function Find-Skills([int]$days) {
  $since = [DateTime]::UtcNow.AddDays(-$days).ToString('yyyy-MM-dd')
  $map = @{}
  foreach ($t in 'claude-skills', 'agent-skills') {
    $q = [uri]::EscapeDataString("topic:$t created:>$since")
    try {
      $r = Invoke-RestMethod "https://api.github.com/search/repositories?q=$q&sort=stars&order=desc&per_page=20" -Headers $gh -TimeoutSec 30
      foreach ($x in $r.items) { $map[$x.full_name.ToLower()] = $x }
    } catch { Write-Log "GitHub 搜索失败：$t（$($_.Exception.Message)）" }
  }
  $map.Values | Sort-Object stargazers_count -Descending | ForEach-Object {
    $lic = if ($_.license) { $_.license.spdx_id } else { $null }
    $l = if (-not $lic -or $lic -eq 'NOASSERTION') { 'u' } elseif ($lic -match '^(MIT|Apache|BSD|ISC|Unlicense|MPL|0BSD|CC0|Zlib)') { 'c' } elseif ($lic -match 'GPL') { 'p' } else { 'u' }
    $age = [Math]::Max(1, [int][Math]::Round(([DateTime]::UtcNow - ([DateTime]$_.created_at).ToUniversalTime()).TotalDays))
    [pscustomobject]@{ repo = $_.full_name; n = $_.name; d = $(if ($_.description) { $_.description.Trim() } else { '' }); stars = [int]$_.stargazers_count; l = $l; age = $age }
  }
}

try {
  if (-not (Test-Path $target)) { throw '仓库里找不到 index.html' }
  $html = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
  if ($html.IndexOf($tag) -lt 0) { throw '网页里找不到 gh-trend 资料区块' }
  # 读回上一次的译文
  try {
    $a0 = $html.IndexOf($tag) + $tag.Length
    $old = $html.Substring($a0, $html.IndexOf('</script>', $a0) - $a0).Replace('<\/', '</') | ConvertFrom-Json
    if ($old.trans) { foreach ($p in $old.trans.PSObject.Properties) { $script:trans[$p.Name] = @{ s = $p.Value.s; z = $p.Value.z } } }
  } catch { }

  # ---------- 1. GitHub Trending（本周） ----------
  $best = @{}; $okPages = 0
  foreach ($lang in $langs) {
    $url = if ($lang) { "https://github.com/trending/$([uri]::EscapeDataString($lang))?since=weekly" } else { 'https://github.com/trending?since=weekly' }
    try {
      $rows = Get-Trending ((Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 25 -UserAgent $ua).Content)
      if ($rows.Count) { $okPages++ }
      foreach ($r in $rows) { $k = $r.repo.ToLower(); if (-not $best.ContainsKey($k) -or $best[$k].gain -lt $r.gain) { $best[$k] = $r } }
    } catch { Write-Log "Trending 读取失败：$(if ($lang) { $lang } else { '总榜' })" }
    Start-Sleep -Milliseconds 400
  }
  $ai = @($best.Values | Where-Object { ($_.repo -replace '[-_/.]', ' ') + ' ' + $_.d -match $aiRx } | Sort-Object gain -Descending)

  # ---------- 2. 新上线的 Skills ----------
  $recent30 = @(Find-Skills 30)
  $recent7 = @(Find-Skills 7)
  $top = New-Object System.Collections.ArrayList
  $ai | Select-Object -First 10 | ForEach-Object { [void]$top.Add($_) }
  $seen = @{}; foreach ($x in $top) { $seen[$x.repo.ToLower()] = 1 }
  foreach ($x in $recent30) { if ($top.Count -ge 10) { break }; if (-not $seen.ContainsKey($x.repo.ToLower())) { [void]$top.Add($x); $seen[$x.repo.ToLower()] = 1 } }
  if (-not $top.Count) { throw '抓不到任何资料，保留上一次的结果' }

  # ---------- 3. 精选 Skills 的星数 ----------
  $stars = [ordered]@{}; $starOk = 0
  $repos = [regex]::Matches($html, "P_\('[^']*','[^']*','[^']*','[^']*','[a-z]','[^']*',\d,'([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
  foreach ($repo in $repos) {
    try { $stars[$repo.ToLower()] = [int](Invoke-RestMethod "https://api.github.com/repos/$repo" -Headers $gh -TimeoutSec 20).stargazers_count; $starOk++ } catch { }
  }

  # ---------- 4. 不在精选里的项目，介绍翻成中文 ----------
  $curated = @{}; foreach ($r in $repos) { $curated[$r.ToLower()] = 1 }
  $viral = @($recent7 | Select-Object -First 12)
  $used = @{}
  foreach ($x in @($top) + $viral) {
    if ($curated.ContainsKey($x.repo.ToLower())) { continue }
    $x | Add-Member -Force -NotePropertyName dz -NotePropertyValue (Get-Zh $x.repo $x.d)
    $used[$x.repo.ToLower()] = 1
  }
  $transOut = [ordered]@{}
  foreach ($k in $script:trans.Keys) { if ($used.ContainsKey($k)) { $transOut[$k] = $script:trans[$k] } }

  # ---------- 写回 index.html ----------
  $data = [ordered]@{
    t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    updatedTime = $now.ToString('yyyy-MM-dd HH:mm')
    source = $(if ($ai.Count) { 'trending' } else { 'search' })
    langs = $okPages
    top = @($top)
    viral = $viral
    stars = $stars
    trans = $transOut
  }
  $json = ($data | ConvertTo-Json -Depth 6 -Compress).Replace('</', '<\/')
  $a = $html.IndexOf($tag) + $tag.Length; $b = $html.IndexOf('</script>', $a)
  [IO.File]::WriteAllText($target, $html.Substring(0, $a) + $json + $html.Substring($b), $utf8)
  Write-Log "已更新：Trending $okPages/$($langs.Count) 页、AI 项目 $($ai.Count) 个、爆红 $([Math]::Min(12, $recent7.Count)) 个、精选星数 $starOk/$(@($repos).Count) 个、新翻译 $script:transNew 则"
} catch {
  Write-Log "更新失败：$($_.Exception.Message)"
  exit 1
}
