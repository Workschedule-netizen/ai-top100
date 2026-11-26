# AI 工具 TOP100 —— 每月更新（GitHub Actions 每月第一次执行时跑；平常会自动跳过）
# 1. 汇率：open.er-api.com 公开汇率（不需要金钥）
# 2. 网站流量：七大对话助手的 Similarweb 月访问量，以及 Semrush 读不到最新数据的工具
# 3. 价格：50 个工具到官方价格页重新核对
# 2、3 由 Claude（网页搜索 + 网页读取）查证，需要在 GitHub Secrets 设定 ANTHROPIC_API_KEY；没设定就只更新汇率。
# 防错：Claude 交回的每个数字都要附上来源原文；脚本会确认原文真的出现在读到的网页里、而且含有该数字，
#       数字和旧值差太多也不收。任何一项查不到或对不上，就保留原本的资料，不会乱改。
param([switch]$Force)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'index.html'
$logFile = Join-Path $here 'update.log'
$utf8 = New-Object Text.UTF8Encoding $false
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36'
$model = if ($env:CLAUDE_MODEL) { $env:CLAUDE_MODEL } else { 'claude-opus-5-5' }

$tz = $null
foreach ($id in 'Asia/Taipei', 'Taipei Standard Time') { try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
$now = if ($tz) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::UtcNow.AddHours(8) }
$month = $now.ToString('yyyy-MM')
function Write-Log($msg) {
  $line = $now.ToString('yyyy-MM-dd HH:mm') + '  [每月] ' + $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}
function Format-Count($v) {
  if ($v -ge 1e8) { '{0:0.##} 亿' -f ($v / 1e8) } elseif ($v -ge 1e4) { '{0:0.#} 万' -f ($v / 1e4) } else { '{0:N0} ' -f $v }
}

# ---------- 读写网页里的 JSON 资料区块 ----------
function Read-Block([string]$html, [string]$id) {
  $tag = '<script type="application/json" id="' + $id + '">'
  $a = $html.IndexOf($tag); if ($a -lt 0) { throw "网页里找不到 $id 资料区块" }
  $a += $tag.Length; $b = $html.IndexOf('</script>', $a)
  $html.Substring($a, $b - $a).Replace('<\/', '</') | ConvertFrom-Json
}
function Write-Block([string]$html, [string]$id, $obj) {
  $tag = '<script type="application/json" id="' + $id + '">'
  $a = $html.IndexOf($tag) + $tag.Length; $b = $html.IndexOf('</script>', $a)
  # 所有 < 都写成 <，资料里就算出现 </script> 也拆不开网页
  $lt = [string][char]92 + 'u003c'
  $html.Substring(0, $a) + ($obj | ConvertTo-Json -Depth 20 -Compress).Replace('<', $lt) + $html.Substring($b)
}

$html = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$data = Read-Block $html 'ranking-data'
$pr = Read-Block $html 'price-tiers'
if (-not $Force -and $data.monthlyRunOn -eq $month) { Write-Host "本月（$month）已经更新过，跳过"; exit 0 }
# 先记下“本月已执行”：万一中途逾时被中断，下次也不会重跑、重复花费；已查完的部分每批都会先存档
$data | Add-Member -Force -NotePropertyName monthlyRunOn -NotePropertyValue $month
function Save-All {
  $script:html = Write-Block $script:html 'ranking-data' $data
  $script:html = Write-Block $script:html 'price-tiers' $pr
  [IO.File]::WriteAllText($target, $script:html, $utf8)
}

# ---------- 1. 汇率（台币为基准：1 美元 = ? 台币） ----------
try {
  $fx = Invoke-RestMethod 'https://open.er-api.com/v6/latest/USD' -TimeoutSec 30
  if ($fx.result -eq 'success' -and $fx.rates.TWD -gt 20 -and $fx.rates.TWD -lt 50) {
    $twd = [double]$fx.rates.TWD
    $pr.fx.USD = [Math]::Round($twd, 2)
    $pr.fx.EUR = [Math]::Round($twd / [double]$fx.rates.EUR, 2)
    $pr.fx.CNY = [Math]::Round($twd / [double]$fx.rates.CNY, 2)
    $pr.fxDate = $month
    Write-Log "汇率已更新：1 USD = $($pr.fx.USD) TWD、1 EUR = $($pr.fx.EUR)、1 CNY = $($pr.fx.CNY)"
  }
} catch { Write-Log "汇率读取失败，保留原值（$($_.Exception.Message)）" }
Save-All

# ---------- Claude：网页搜索 + 网页读取 ----------
$key = $env:ANTHROPIC_API_KEY
function Invoke-Claude([string]$system, [string]$prompt) {
  $headers = @{ 'x-api-key' = $key; 'anthropic-version' = '2026-10-21'; 'anthropic-beta' = 'server-side-fallback-2026-07-01' }
  $tools = @(
    @{ type = 'web_search_20260209'; name = 'web_search'; max_uses = 12 },
    @{ type = 'web_fetch_20260209'; name = 'web_fetch'; max_uses = 12; max_content_tokens = 30000 }
  )
  $messages = New-Object System.Collections.ArrayList
  [void]$messages.Add(@{ role = 'user'; content = $prompt })
  $blocks = New-Object System.Collections.ArrayList
  for ($turn = 0; $turn -lt 6; $turn++) {
    $body = @{ model = $model; max_tokens = 16000; system = $system; tools = $tools; messages = $messages;
               output_config = @{ effort = 'medium' }; fallbacks = 'default' } | ConvertTo-Json -Depth 40 -Compress
    $api = if ($env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL.TrimEnd('/') } else { 'https://api.anthropic.com' }
    $r = Invoke-RestMethod "$api/v1/messages" -Method Post -Headers $headers -TimeoutSec 900 `
         -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
    foreach ($c in $r.content) { [void]$blocks.Add($c) }
    if ($r.stop_reason -eq 'pause_turn') { [void]$messages.Add(@{ role = 'assistant'; content = $r.content }); continue }
    if ($r.stop_reason -eq 'refusal') { throw '模型拒绝回答' }
    break
  }
  $text = ($blocks | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
  $m = [regex]::Match($text, '```json\s*([\s\S]+?)```')
  $json = if ($m.Success) { $m.Groups[1].Value } else { $text.Substring([Math]::Max(0, $text.IndexOf('{'))) }
  [pscustomobject]@{ result = ($json | ConvertFrom-Json); pages = @(Get-FetchedText $blocks) }
}
# 从 web_fetch 结果里取出网页全文，供核对原文用
function Get-FetchedText($blocks) {
  foreach ($b in $blocks) {
    if ($b.type -ne 'web_fetch_tool_result') { continue }
    $doc = $b.content.content
    if ($doc -and $doc.source -and $doc.source.data -and $doc.source.type -eq 'text') { [pscustomobject]@{ url = $b.content.url; text = [string]$doc.source.data } }
  }
}
function Get-Norm([string]$s) { ([Net.WebUtility]::HtmlDecode($s) -replace '<[^>]+>', ' ' -replace '[\s ]+', ' ').Trim().ToLower() }
# 原文必须真的出现在读到的网页里；Claude 读到的全文找不到时，脚本自己再读一次来源网址
function Test-Quote([string]$quote, $pages, [string]$url) {
  $q = Get-Norm $quote
  if ($q.Length -lt 6) { return $false }
  foreach ($p in $pages) { if ((Get-Norm $p.text).Contains($q)) { return $true } }
  if ($url -match '^https?://') {
    try { if ((Get-Norm (Invoke-WebRequest -UseBasicParsing $url -UserAgent $ua -TimeoutSec 30).Content).Contains($q)) { return $true } } catch { }
  }
  $false
}
# 原文里有没有这个价格数字（20 也接受 20.00，但不会把 120 或 2.0 当成 20）
function Test-Num([string]$text, $n) {
  $text -match ('(?<![\d.])' + [regex]::Escape(([double]$n).ToString('0.##')) + '(?:\.0+)?(?![\d])')
}
# 把原文里的数字（含 K/M/B、million、billion、万、亿）都换算成“百万”，用来比对
function Get-Millions([string]$s) {
  $s = $s -replace '(?<=\d),(?=\d{3})', ''
  foreach ($m in [regex]::Matches($s, '([\d]+(?:\.\d+)?)\s*(billion|million|thousand|bn|[KMB]\b|亿|万)?', 'IgnoreCase')) {
    $v = [double]$m.Groups[1].Value
    switch -regex ($m.Groups[2].Value) {
      '^(?i)(billion|bn|b)$' { $v * 1000 } '^(?i)(million|m)$' { $v } '^(?i)(thousand|k)$' { $v / 1000 }
      '^亿$' { $v * 100 } '^万$' { $v / 100 } default { $v / 1e6 }
    }
  }
}

if (-not $key) {
  Write-Log '没有设定 ANTHROPIC_API_KEY，这次只更新汇率（流量与价格保留原值）'
} else {
  $tools = @($data.items | Where-Object { $_.type -eq '工具' })

  # ---------- 2. 网站流量 ----------
  $limit = $now.AddMonths(-2).ToString('yyyy-MM')
  $traffic = @(foreach ($it in $tools) {
    $s = $it.src; $mm = [regex]::Match([string]$it.metric, 'Semrush (\d{4}-\d\d)')
    $domain = if ($s.domain) { $s.domain } else { ([uri]$it.url).Host -replace '^www\.', '' }
    if ($s.mode -eq 'chatbot') { [pscustomobject]@{ it = $it; kind = 'sw'; domain = $domain; old = [double]$s.sw } }
    elseif ($s.mode -eq 'fixed' -or ($s.mode -eq 'semrush' -and ($s.alt -or ($mm.Success -and $mm.Groups[1].Value -lt $limit)))) {
      [pscustomobject]@{ it = $it; kind = 'ev'; domain = $domain; old = [double]$s.ev }
    }
  })
  $sysT = 'You research website traffic statistics. For each domain, find the total monthly visits for the most recent full month that has published data, preferring Similarweb (similarweb.com pages or Similarweb reports) and otherwise Semrush. Fetch the page that states the number with web_fetch. Never estimate or compute numbers yourself; if you cannot find a stated figure, set found to false. Copy the sentence or table row that states the number exactly, character for character, into quote.'
  for ($i = 0; $i -lt $traffic.Count; $i += 6) {
    $batch = @($traffic[$i..([Math]::Min($i + 5, $traffic.Count - 1))])
    $list = ($batch | ForEach-Object { "- id: $($_.it.id); domain: $($_.domain); previous value: about $([Math]::Round($_.old, 1)) million visits/month" }) -join "`n"
    $prompt = "Today is $($now.ToString('yyyy-MM-dd')). Find the latest monthly total visits for these websites:`n$list`n`nReply with only a JSON code block: {""results"":[{""id"":""..."",""found"":true,""visits_millions"":123.4,""month"":""YYYY-MM"",""source_name"":""Similarweb"",""source_url"":""https://..."",""quote"":""exact text from the page""}]}"
    try {
      $res = Invoke-Claude $sysT $prompt
      foreach ($r in $res.result.results) {
        $t = $batch | Where-Object { $_.it.id -eq $r.id } | Select-Object -First 1
        if (-not $t -or -not $r.found) { continue }
        $v = [double]$r.visits_millions
        $ok = (Test-Quote $r.quote $res.pages $r.source_url) -and (@(Get-Millions $r.quote | Where-Object { [Math]::Abs($_ - $v) -le $v * 0.03 }).Count -gt 0) -and
              ($v -ge $t.old / 3) -and ($v -le $t.old * 3) -and ($r.month -match '^\d{4}-\d\d$') -and ($r.month -le $month)
        if (-not $ok) { Write-Log "流量未采用（核对不过）：$($t.it.name) $v 百万（$($r.source_url)）"; continue }
        $src = if ($r.source_name -match 'semrush') { 'Semrush' } else { 'Similarweb' }
        if ($t.kind -eq 'sw') {
          $t.it.src.sw = [Math]::Round($v, 2)
          $t.it.src | Add-Member -Force -NotePropertyName swYm -NotePropertyValue $r.month
        } else {
          $t.it.src.ev = [Math]::Round($v, 2)
          $t.it.src | Add-Member -Force -NotePropertyName alt -NotePropertyValue 1
          $t.it.metric = "$src $($r.month)：$(Format-Count ($v * 1e6))次（每月自动查证）"
        }
        Write-Log "流量已更新：$($t.it.name) $src $($r.month) $([Math]::Round($v, 1)) 百万"
      }
    } catch { Write-Log "流量查证失败（$($_.Exception.Message)）" }
    Save-All
  }

  # ---------- 3. 价格 ----------
  $sysP = @'
You check the current prices of AI tools on their official pricing pages. Use web_fetch on the official pricing page (find it with web_search if needed); ignore third-party sites. Report US-dollar prices as shown to a US visitor unless the tool only sells in another currency.
For each tool, compare with the current data you are given:
- If nothing changed, return status "unchanged".
- If anything changed, return status "changed" with the full new data in the same style and language (Simplified Chinese) as the current data.
- If you cannot read the official page, return status "unavailable".
Field meanings: price is one of 免费 (completely free), 有免费版 (free tier plus paid plans), 付费 (must pay). from is the cheapest paid monthly price like "$8/月起" ("起" when there are several paid plans), or "免费". plans is one short Chinese sentence listing the plans. tiers is a list of plans: n = plan name ("@free" for the free tier, "@api" for usage-based API), p = monthly price as a number, y = monthly price when billed yearly, u = "seat" (per user), "usage" (pay as you go) or "img", c = currency code when not USD, a = 1 if the price is approximate, ao = 1 if only sold yearly.
For every tool marked changed or unchanged, quotes must contain text copied exactly, character for character, from the official pricing page, covering every price in the (new or current) tiers.
'@
  $priceIds = @($tools | ForEach-Object { $_.id })
  $checked = 0; $changed = 0
  for ($i = 0; $i -lt $priceIds.Count; $i += 5) {
    $ids = @($priceIds[$i..([Math]::Min($i + 4, $priceIds.Count - 1))])
    $cur = foreach ($id in $ids) {
      $it = $tools | Where-Object { $_.id -eq $id }
      [ordered]@{ id = $id; name = $it.name; website = $it.url; price = $it.price; from = $it.from; plans = $it.plans; tiers = $pr.tiers.$id }
    }
    $prompt = "Today is $($now.ToString('yyyy-MM-dd')). Current data:`n" + ($cur | ConvertTo-Json -Depth 10) +
      "`n`nReply with only a JSON code block: {""results"":[{""id"":""..."",""status"":""unchanged|changed|unavailable"",""source_url"":""https://..."",""quotes"":[""...""],""price"":""..."",""from"":""..."",""plans"":""..."",""tiers"":[...]}]}"
    try {
      $res = Invoke-Claude $sysP $prompt
      foreach ($r in $res.result.results) {
        $it = $tools | Where-Object { $_.id -eq $r.id } | Select-Object -First 1
        if (-not $it) { continue }
        if ($r.status -notin @('changed', 'unchanged')) { Write-Log "价格读不到官方页面，保留原值：$($it.name)"; continue }
        # 不论有没有变动，报的价格（没变就是现有价格）都要在官方页面原文里找得到
        $tiers = if ($r.status -eq 'changed') { @($r.tiers) } else { @($pr.tiers.($it.id)) }
        $quotes = @($r.quotes)
        $qOk = $quotes.Count -gt 0 -and @($quotes | Where-Object { -not (Test-Quote $_ $res.pages $r.source_url) }).Count -eq 0
        # 每个月费都要出现在原文；年付价（y）可以是“每月折合”或“一年总价”（例如 15 或 180）
        $joined = $quotes -join ' '
        $bad = @($tiers | Where-Object {
          ($_.p -and [double]$_.p -gt 0 -and -not (Test-Num $joined $_.p)) -or
          ($_.y -and [double]$_.y -gt 0 -and -not (Test-Num $joined $_.y) -and -not (Test-Num $joined ([double]$_.y * 12)))
        })
        $nOk = $bad.Count -eq 0
        if ($r.status -eq 'unchanged') {
          if ($qOk -and $nOk) { $checked++ } else { Write-Log "价格回报没变，但原文核对不过，不计入：$($it.name)" }
          continue
        }
        $fOk = $r.price -in @('免费', '有免费版', '付费') -and @($r.tiers).Count -gt 0 -and ($r.from -eq '免费' -or $r.from -match '[$€¥]\s*[\d.]+')
        if (-not ($qOk -and $nOk -and $fOk)) { Write-Log "价格未采用（核对不过）：$($it.name)（$($r.source_url)）"; continue }
        $it.price = $r.price; $it.from = $r.from; $it.plans = $r.plans; $it.priceNote = $r.plans
        $pr.tiers | Add-Member -Force -NotePropertyName $it.id -NotePropertyValue @($r.tiers)
        $checked++; $changed++
        Write-Log "价格已更新：$($it.name) → $($r.plans)"
      }
    } catch { Write-Log "价格查证失败（$($_.Exception.Message)）" }
    Save-All
  }
  if ($checked -gt 0) { $data.pricesCheckedOn = $now.ToString('yyyy-MM-dd') }
  Write-Log "价格核对完成：$checked / $($priceIds.Count) 项确认，其中 $changed 项有变动"
}

Save-All
Write-Log '每月更新完成'
