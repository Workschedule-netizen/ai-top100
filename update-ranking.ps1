# AI 工具与技能 TOP100 —— 云端自动更新脚本（GitHub Actions 版，不需要开电脑、不需要 Claude）
# 每次执行：抓 skills.sh 安装量、ClawHub 下载量和 GitHub 星标，按公式重算技能榜。
# 每天第一次执行：另外抓 Semrush 网站流量，重算工具榜，并把名次变化基准往前推一天。
# 结果直接写回仓库里的 index.html，由 GitHub Actions 提交后，Cloudflare Pages 自动发布。
param([switch]$Force)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'index.html'
$logFile = Join-Path $here 'update.log'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36'
$utf8 = New-Object Text.UTF8Encoding $false
$tag = '<script type="application/json" id="ranking-data">'

# 网页上显示的时间用台北 / 北京时间（UTC+8）
$tz = $null
foreach ($id in 'Asia/Taipei', 'Taipei Standard Time') { try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
$now = if ($tz) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::UtcNow.AddHours(8) }
$today = $now.ToString('yyyy-MM-dd')

function Write-Log($msg) {
  $line = $now.ToString('yyyy-MM-dd HH:mm') + '  ' + $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}
function ConvertTo-Number($text) {
  $m = [regex]::Match($text, '([\d\.]+)\s*([KMB]?)')
  $v = [double]$m.Groups[1].Value
  switch ($m.Groups[2].Value) { 'K' { $v *= 1e3 } 'M' { $v *= 1e6 } 'B' { $v *= 1e9 } }
  $v
}
function Format-Count($v) {
  if ($v -ge 1e8) { '{0:0.##} 亿' -f ($v / 1e8) } elseif ($v -ge 1e4) { '{0:0.#} 万' -f ($v / 1e4) } else { '{0:N0} ' -f $v }
}
function Get-Page($url) { (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 25 -UserAgent $ua).Content }
$ghHeaders = @{ 'User-Agent' = 'ai-top100-updater' }
if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

# ---------- 读取现有数据 ----------
if (-not (Test-Path $target)) { throw '仓库里找不到 index.html' }
$html = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$a = $html.IndexOf($tag); if ($a -lt 0) { throw '网页里找不到 ranking-data 数据区块' }
$a += $tag.Length; $b = $html.IndexOf('</script>', $a)
$data = $html.Substring($a, $b - $a).Replace('<\/', '</') | ConvertFrom-Json
$daily = $Force -or ($data.toolsRefreshedOn -ne $today)

try {
  # ---------- 技能：skills.sh 安装量 ----------
  $repoCache = @{}
  function Get-RepoInstalls($repo) {
    if (-not $repoCache.ContainsKey($repo)) {
      $h = @{}
      try {
        $c = Get-Page "https://www.skills.sh/$repo"
        $pattern = 'href="/' + [regex]::Escape($repo) + '/([^"/]+)".{0,400}?font-mono text-sm text-foreground">([\d\.]+[KMB]?)<'
        foreach ($m in [regex]::Matches($c, $pattern, 'IgnoreCase,Singleline')) { $h[$m.Groups[1].Value] = ConvertTo-Number $m.Groups[2].Value }
      } catch { Write-Log "skills.sh 读取失败：$repo（$($_.Exception.Message)）" }
      $repoCache[$repo] = $h
      Start-Sleep -Milliseconds 400
    }
    $repoCache[$repo]
  }
  # ---------- 技能：GitHub 星标 ----------
  $starCache = @{}
  function Get-Stars($repo) {
    if (-not $starCache.ContainsKey($repo)) {
      try { $starCache[$repo] = [double](Invoke-RestMethod "https://api.github.com/repos/$repo" -Headers $ghHeaders).stargazers_count }
      catch { $starCache[$repo] = $null; Write-Log "GitHub 读取失败：$repo" }
    }
    $starCache[$repo]
  }
  # ---------- 技能：ClawHub 下载量（LinklyAI 每日汇总） ----------
  $claw = @{}
  $csvUrls = @('https://raw.githubusercontent.com/LinklyAI/best-skills/main/data/latest/rankings/best-100.csv',
               ('https://raw.githubusercontent.com/LinklyAI/best-skills/main/data/{0}/rankings/best-100.csv' -f $today),
               ('https://raw.githubusercontent.com/LinklyAI/best-skills/main/data/{0}/rankings/best-100.csv' -f $now.AddDays(-1).ToString('yyyy-MM-dd')))
  foreach ($u in $csvUrls) {
    try {
      $rows = (Get-Page $u) -split "`n" | ConvertFrom-Csv
      foreach ($r in $rows) { if ($r.slug_clawhub -and $r.downloads_clawhub) { $claw[$r.slug_clawhub] = [double]$r.downloads_clawhub } }
      if ($claw.Count) { break }
    } catch { }
  }

  $skillsUpdated = 0
  foreach ($it in ($data.items | Where-Object { $_.type -eq '技能' })) {
    $s = $it.src; $inst = $null; $stars = 0
    if ($s.claw) { if ($claw.ContainsKey($s.claw)) { $inst = $claw[$s.claw] } }
    elseif ($s.sk) {
      $h = Get-RepoInstalls $s.sk
      if ($h.Count) {
        if ($s.names) { $vals = @($s.names | ForEach-Object { $h[$_] } | Where-Object { $_ }); if ($vals.Count) { $inst = ($vals | Measure-Object -Maximum).Maximum } }
        else { $inst = ($h.Values | Measure-Object -Maximum).Maximum }
      }
    }
    if ($s.gh) { $st = Get-Stars $s.gh; if ($st) { $stars = $st } }
    if ($inst) {
      $s.ev = [Math]::Round([Math]::Max($inst, [Math]::Sqrt($inst * $stars * 5)))
      $label = if ($s.claw) { 'ClawHub 下载' } elseif (-not $s.names) { 'skills.sh 主技能安装' } elseif (@($s.names).Count -gt 1) { 'skills.sh 单项最高安装' } else { 'skills.sh 安装' }
      $it.metric = "$label $(Format-Count $inst)次" + $(if ($stars) { " · GitHub $(Format-Count $stars)星" } else { '' })
      $skillsUpdated++
    }
  }
  Write-Log "技能数据已刷新 $skillsUpdated / 50 项"

  # ---------- 工具：Semrush 网站流量（每天一次） ----------
  $toolsUpdated = 0
  if ($daily) {
    $months = @{ January=1; February=2; March=3; April=4; May=5; June=6; July=7; August=8; September=9; October=10; November=11; December=12 }
    function Get-Semrush($domain) {
      try {
        $c = Get-Page "https://www.semrush.com/website/$domain/overview/"
        $m = [regex]::Match($c, 'In (\w+) \S+ received ([\d\.]+[KMB]?) visits')
        if ($m.Success -and $months.ContainsKey($m.Groups[1].Value)) {
          $mo = $months[$m.Groups[1].Value]; $yr = if ($mo -gt $now.Month) { $now.Year - 1 } else { $now.Year }
          return @{ ym = ('{0}-{1:00}' -f $yr, $mo); v = (ConvertTo-Number $m.Groups[2].Value) }
        }
      } catch { }
      $null
    }
    foreach ($it in ($data.items | Where-Object { $_.type -eq '工具' })) {
      $s = $it.src
      if ($s.mode -eq 'fixed' -or -not $s.domain) { continue }
      $r = Get-Semrush $s.domain
      Start-Sleep -Milliseconds 700
      if (-not $r) { continue }
      switch ($s.mode) {
        'semrush' { $s.ev = [Math]::Round($r.v / 1e6, 2); $it.metric = "Semrush $($r.ym)：$(Format-Count $r.v)次" }
        'chatbot' {
          $g = [Math]::Sqrt(($r.v / 1e6) * [double]$s.sw); $s.ev = [Math]::Round($g, 2)
          $it.metric = "Semrush $($r.ym)：$(Format-Count $r.v)次；Similarweb 2026-09：约 $(Format-Count ([double]$s.sw * 1e6))次；几何平均约 $(Format-Count ($g * 1e6))次"
        }
        'survey' { $s.ev = [Math]::Round([Math]::Max([double]$s.survey, $r.v / 1e6), 2) }
      }
      $toolsUpdated++
    }
    Write-Log "工具流量已刷新 $toolsUpdated 项（读不到的保留原数字）"
  }

  # ---------- 按公式重算排名 ----------
  function Update-Rank($type) {
    $g = @($data.items | Where-Object { $_.type -eq $type } | Sort-Object { [double]$_.src.ev } -Descending)
    $mx = [Math]::Log10([double]$g[0].src.ev); $mn = [Math]::Log10([double]$g[-1].src.ev); $r = 0
    foreach ($it in $g) { $r++; $it.rank = $r; $it.score = [Math]::Round(40 + 60 * ([Math]::Log10([double]$it.src.ev) - $mn) / ($mx - $mn), 1) }
  }
  if ($daily) { foreach ($it in $data.items) { $it.prevRank = $it.rank; $it.isNew = $false } }
  Update-Rank '技能'
  if ($daily) { Update-Rank '工具' }
  $data.items = @(@($data.items | Where-Object { $_.type -eq '工具' } | Sort-Object rank) + @($data.items | Where-Object { $_.type -eq '技能' } | Sort-Object rank))

  $data.updatedAt = $today
  $data.updatedTime = $now.ToString('yyyy-MM-dd HH:mm')
  if ($daily) {
    $data | Add-Member -Force -NotePropertyName toolsRefreshedOn -NotePropertyValue $today
    $data.edition = [int]$data.edition + 1
    $log = @($data.changelog) + [pscustomobject]@{ date = $today; note = "云端自动更新：刷新 $toolsUpdated 个工具的网站流量与 $skillsUpdated 个技能的安装量，并按公式重算排名。" }
    $data.changelog = @($log | Select-Object -Last 20)
  }

  # ---------- 写回 index.html ----------
  $json = ($data | ConvertTo-Json -Depth 12 -Compress).Replace('</', '<\/')
  [IO.File]::WriteAllText($target, $html.Substring(0, $a) + $json + $html.Substring($b), $utf8)
  Write-Log "网页已更新（$($data.updatedTime)）"
} catch {
  Write-Log "更新失败：$($_.Exception.Message)"
  exit 1
}

# 日志只保留最近 300 行
$lines = @(Get-Content $logFile -Encoding UTF8)
if ($lines.Count -gt 300) { $lines | Select-Object -Last 300 | Set-Content $logFile -Encoding UTF8 }
