param([switch]$SelfTest, [switch]$Report, [switch]$Preview, [switch]$PreviewScan)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

$csvEnc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'UTF8BOM' } else { 'UTF8' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ================= 字体解析 =================
function BE16([byte[]]$b, [int]$p) { ([int]$b[$p] * 256) + [int]$b[$p + 1] }
function BE32([byte[]]$b, [int]$p) {
  ([int64]$b[$p] * 16777216) + ([int64]$b[$p + 1] * 65536) + ([int64]$b[$p + 2] * 256) + [int64]$b[$p + 3]
}

function GetFontInfo([string]$path) {
  $res = [ordered]@{ Family = ''; Copyright = ''; Manufacturer = ''; Version = ''; License = '' }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 16) { return $null }
    $tag  = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    $base = 0
    if ($tag -eq 'ttcf') { $base = [int](BE32 $bytes 12) }
    $numTables = BE16 $bytes ($base + 4)
    $nameOff = -1
    for ($i = 0; $i -lt $numTables; $i++) {
      $rec = $base + 12 + ($i * 16)
      if ($rec + 16 -gt $bytes.Length) { break }
      $tagName = [System.Text.Encoding]::ASCII.GetString($bytes, $rec, 4)
      if ($tagName -eq 'name') { $nameOff = [int](BE32 $bytes ($rec + 8)); break }
    }
    if ($nameOff -lt 0 -or $nameOff + 6 -gt $bytes.Length) { return $null }
    $count   = BE16 $bytes ($nameOff + 2)
    $strBase = $nameOff + (BE16 $bytes ($nameOff + 4))
    $records = @{}
    for ($i = 0; $i -lt $count; $i++) {
      $r = $nameOff + 6 + ($i * 12)
      if ($r + 12 -gt $bytes.Length) { break }
      $plat = BE16 $bytes $r
      $lang = BE16 $bytes ($r + 4)
      $nid  = BE16 $bytes ($r + 6)
      $len  = BE16 $bytes ($r + 8)
      $off  = BE16 $bytes ($r + 10)
      if ($off + $len -gt $bytes.Length -or $len -le 0) { continue }
      $raw = New-Object byte[] $len
      [Array]::Copy($bytes, $strBase + $off, $raw, 0, $len)
      if ($plat -eq 3 -or $plat -eq 0) { $s = [System.Text.Encoding]::BigEndianUnicode.GetString($raw) }
      elseif ($plat -eq 1) { $s = [System.Text.Encoding]::ASCII.GetString($raw) }
      else { continue }
      $s = $s.Trim()
      if ($s -eq '') { continue }
      $prio = 60
      if ($plat -eq 3 -and $lang -eq 0x804) { $prio = 100 }
      elseif ($plat -eq 3 -and $lang -eq 0x409) { $prio = 90 }
      elseif ($plat -eq 3) { $prio = 80 }
      elseif ($plat -eq 0) { $prio = 75 }
      if (-not $records.ContainsKey($nid) -or $prio -gt $records[$nid].Prio) {
        $records[$nid] = [pscustomobject]@{ Prio = $prio; Text = $s }
      }
    }
    $pick = { param($id) if ($records.ContainsKey([int]$id)) { $records[[int]$id].Text } else { '' } }
    $res.Family       = & $pick 1
    $res.Copyright    = & $pick 0
    $res.Manufacturer = & $pick 8
    $res.Version      = & $pick 5
    $lic = ((& $pick 13) + ' ' + (& $pick 14)).Trim()
    if ($lic.Length -gt 240) { $lic = $lic.Substring(0, 240) + '...' }
    $res.License = $lic
    return [pscustomobject]$res
  }
  catch { return $null }
}

$Rules = @(
  @{ P='仓耳渔阳体|站酷仓耳'; Level='可商用'; Note='站酷与仓耳字库联合发布的公益字体，官方声明免费授权全社会使用（含商用）'; Alt='—'; Priority=305; Name='免费·仓耳站酷' },
  @{ P='思源|Source ?Han|Noto ?(Sans|Serif)|阿里巴巴普惠体|Alibaba ?PuHuiTi|阿里妈妈|Alimama|OPPO ?Sans|MiSans|HarmonyOS ?Sans|得意黑|Smiley ?Sans|站酷|优设|庞门正道|文泉驿|WenQuanYi|霞鹜|LXGW|未来荧黑|Glow ?Sans|Fandol|朱雀仿宋|寒蝉|抖音美好体|猫啃'; Level='可商用'; Note='开源或官方声明免费商用（部分禁止商标注册，需核对条款）'; Alt='—'; Priority=300; Name='免费·开源与厂商免费字体' },
  @{ P='SIL OPEN FONT LICENSE|OFL-1\.1|Apache ?License|Apache-2\.0'; Level='可商用'; Note='字体文件内嵌开源许可声明，通常允许商用；OFL 禁止单独售卖字体文件本身'; Alt='—'; Field='copyright'; Priority=295; Name='免费·内嵌开源许可' },
  @{ P='Project Authors|with Reserved Font Name|This Font Software is licensed under'; Level='可商用'; Note='字体版权字段含开源项目作者声明，通常随附 SIL OFL 许可；仍建议核对官方许可文件'; Alt='—'; Field='copyright'; Priority=292; Name='免费·项目作者开源声明' },
  @{ P='^(微软雅黑|Microsoft ?YaHei|等线|DengXian|微软正黑|Microsoft JhengHei|苹方|PingFang)(?:\s+[A-Za-z\u4e00-\u9fa5]+)?$'; Level='高风险'; Note='系统随附但字形为现代商业设计（微软雅黑=方正兰亭黑），字形版权归第三方字库公司，对外商用发布需授权；属系统文件，删除可能影响系统显示，建议保留并改用免费字体替代'; Alt='思源黑体 / 阿里巴巴普惠体 / MiSans'; Field='family'; Priority=260; Name='高风险·系统内嵌商业字体' },
  @{ P='^(宋体|SimSun|新宋体|NSimSun|黑体|SimHei|楷体|KaiTi|仿宋|FangSong)(?:\s+[A-Za-z\u4e00-\u9fa5]+)?$'; Level='常规'; Note='宋体/黑体/楷体/仿宋等基础字形属公有领域，随 Windows 分发，正常排版输出一般无争议；字库文件本身不可转售'; Alt='—'; Field='family'; Priority=255; Name='常规·公有领域字形系统字体' },
  @{ P='Microsoft Corporation|Monotype|中易|ZhongYi|JIYUKOBO|Segoe|Calibri|Cambria|Arial|Times New Roman|Tahoma|Verdana|Consolas|Yu Gothic|MS Gothic|MingLiU|Batang|Gulim|Malgun|Meiryo'; Level='常规'; Note='随系统/Office 分发的常规字体，正常排版输出一般无争议；字库文件本身不可转售'; Alt='—'; Priority=250; Name='常规·系统办公字体' },
  @{ P='Adobe'; Level='中风险'; Note='Adobe Fonts 订阅字体，授权通常只覆盖 Adobe 应用内使用'; Alt='思源系列'; Priority=240; Name='Adobe Fonts 订阅' },
  @{ P='方正|Founder|FOUNDER|兰亭|汉仪|Hanyi|HANYI|华文|华康|DynaFont|文鼎|Arphic|造字工房|字魂|锐字|腾祥|筑紫|汉鼎|叶根友|仓耳|Canger|喜鹊|华光|新蒂|上首|苏新诗|胡晓波|三极|汉呈|邯郸|王汉宗|刻石录|汉标|郑庆科|荆南|禹卫|创客贴|刘兵克|字研室|HyFont|段宁|茂山|香蕉灵感|福芦灵感|饿了羊|爱点字库|元宝团子|百家造字|罗国成|山海字库|小欣大萌|字耕者|字小魂|向佳红|李旭科|字动力|建首字库|壹禾|安景臣|东篱|方舆字研|文道|字语字库|麦拉风|喵字馆|施申财|梁培生|字悦字型|平方造字'; Level='高风险'; Note='商业字库/权属第三方，商用需另行授权；“免费下载”不等于“免费商用”'; Alt='思源黑体 / 阿里巴巴普惠体 / MiSans'; Priority=200; Name='高风险·商业字库厂商'; Exclude=@('SIL OPEN FONT LICENSE|OFL-1\.1') }
)

# 内置兜底规则（rules.json 缺失/损坏时使用）
$script:RulesBuiltin = $Rules
$rulesPath = Join-Path $scriptDir 'rules.json'
function Load-Rules {
  if (-not (Test-Path $rulesPath)) { $script:Rules = $script:RulesBuiltin; return }
  try {
    $items = [IO.File]::ReadAllText($rulesPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $loaded = @(); $idx = 0
    foreach ($it in $items) {
      if (-not $it.pattern -or -not $it.level) { continue }
      $en = if ($it.PSObject.Properties['enabled']) { [bool]$it.enabled } else { $true }
      if (-not $en) { continue }
      $fld = 'all'; if ($it.PSObject.Properties['field']) { $fld = [string]$it.field }
      $exs = @(); if ($it.PSObject.Properties['exclude']) { $exs = @($it.exclude | Where-Object { $_ }) }
      $pri = 100; if ($it.PSObject.Properties['priority']) { $pri = [int]$it.priority }
      $nm = ''; if ($it.PSObject.Properties['name']) { $nm = [string]$it.name }
      $src = ''; if ($it.PSObject.Properties['source']) { $src = [string]$it.source }
      $loaded += @{ P=[string]$it.pattern; Level=[string]$it.level; Note=[string]$it.note; Alt=[string]$it.alt; Field=$fld; Exclude=$exs; Priority=$pri; Name=$nm; Source=$src; Index=$idx }
      $idx++
    }
    if ($loaded.Count -gt 0) { $script:Rules = $loaded }
    else { $script:Rules = $script:RulesBuiltin }
  } catch { $script:Rules = $script:RulesBuiltin }
}
Load-Rules

# v2 判定：按 priority 降序、同优先级按文件顺序；支持 field 限定字段与 exclude 排除
function GetRisk([string]$family, [string]$copyright, [string]$manufacturer, [string]$file) {
  $fAll = "$family | $copyright | $manufacturer | $file"
  $fmap = @{ all=$fAll; family=$family; copyright=$copyright; manufacturer=$manufacturer; file=$file }
  $ordered = @($script:Rules | Sort-Object -Property @(
    @{ Expression = { if ($null -ne $_.Priority) { -[int]$_.Priority } else { -100 } } },
    @{ Expression = { if ($null -ne $_.Index) { [int]$_.Index } else { 0 } } }
  ))
  foreach ($r in $ordered) {
    $fld = 'all'; if ($r.Field) { $fld = [string]$r.Field }
    if (-not $fmap.ContainsKey($fld)) { $fld = 'all' }
    $target = [string]$fmap[$fld]
    if ($target -notmatch [string]$r.P) { continue }
    if ($r.Exclude) {
      $hitEx = $false
      foreach ($ex in @($r.Exclude)) { if ($fAll -match [string]$ex) { $hitEx = $true; break } }
      if ($hitEx) { continue }
    }
    $m = [regex]::Match($target,[string]$r.P)
    $ev = if ($m.Success) { $m.Value } else { '' }
    $rn = '内置规则'; if ($r.Name) { $rn = [string]$r.Name }
    $rs = ''; if ($r.Source) { $rs = [string]$r.Source }
    return @{ Level=$r.Level; Note=$r.Note; Alt=$r.Alt; Name=$rn; Source=$rs; Field=$fld; Evidence=$ev }
  }
  return @{ Level='待核实'; Note='未匹配已知清单，需人工核对授权来源'; Alt='思源黑体（最稳妥的替代）'; Name='兜底·未匹配'; Source=''; Field=''; Evidence='' }
}

function Get-FontRows {
  param([scriptblock]$OnProgress)
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
    if (-not (Test-Path $k)) { continue }
    $props = Get-ItemProperty -Path $k
    $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
      $entries.Add([pscustomobject]@{ Display = $_.Name; File = [string]$_.Value })
    }
  }
  $userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
  if (Test-Path $userFontDir) {
    Get-ChildItem $userFontDir -File | Where-Object { $_.Extension -in '.ttf', '.ttc', '.otf' } | ForEach-Object {
      $entries.Add([pscustomobject]@{ Display = $_.BaseName; File = $_.FullName })
    }
  }

  $seen = @{}
  $rows = New-Object System.Collections.Generic.List[object]
  $n = 0
  $totalEntries = $entries.Count
  foreach ($e in $entries) {
    $p = $e.File
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $env:WINDIR "Fonts\$p" }
    if (-not (Test-Path $p)) { continue }
    $key = $p.ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $n++
    if ($OnProgress -and ($n % 20 -eq 0)) { & $OnProgress $n $totalEntries ([System.IO.Path]::GetFileName($p)) }

    $display = ($e.Display -replace '\s*\((TrueType|OpenType|All res)\)\s*$', '').Trim()
    $ext = [System.IO.Path]::GetExtension($p).ToLower()
    $info = $null
    if ($ext -in '.ttf', '.ttc', '.otf') { $info = GetFontInfo $p }

    $family = if ($info -and $info.Family) { $info.Family } elseif ($display) { $display } else { [System.IO.Path]::GetFileNameWithoutExtension($p) }
    $copy   = if ($info) { $info.Copyright } else { '' }
    $manu   = if ($info) { $info.Manufacturer } else { '' }
    $fname  = [System.IO.Path]::GetFileName($p)
    $risk   = GetRisk $family $copy $manu $fname
    if ($risk.Level -eq '待核实' -and -not $copy -and -not $manu -and $p -like '*\Windows\Fonts\*') {
      $risk = @{ Level='常规'; Note='系统自带且文件内无厂商版权信息，字形多为公有领域，商用输出一般无争议；如为自行安装的字体需另查来源'; Alt='—'; Name='兜底·系统字体无版权'; Source=''; Evidence='' }
    }
    $rn2 = '内置规则'; if ($risk.Name) { $rn2 = [string]$risk.Name }
    $rs2 = ''; if ($risk.Source) { $rs2 = [string]$risk.Source }
    $rev = ''; if ($risk.Evidence) { $rev = [string]$risk.Evidence }

    $rows.Add([pscustomobject]@{
      序号     = $n
      字体名   = $family
      文件名   = [System.IO.Path]::GetFileName($p)
      路径     = $p
      厂商版权 = $manu
      版权声明 = $copy
      判定     = $risk.Level
      说明     = $risk.Note
      建议替代 = $risk.Alt
      命中规则 = $rn2
      判定依据 = $rs2
      命中片段 = $rev
    })
  }
  return $rows
}

function New-ReportHtml($rows, $outPath) {
  $total = $rows.Count
  $lv = @(
    @{ N='高风险'; D='商用需授权'; C='#ef4444' },
    @{ N='中风险'; D='需确认授权范围'; C='#f97316' },
    @{ N='待核实'; D='需人工核对'; C='#eab308' },
    @{ N='常规'; D='系统自带，正常使用'; C='#94a3b8' },
    @{ N='可商用'; D='开源 / 免费商用'; C='#22c55e' }
  )
  $css = @'
:root{--bg:#f6f8fc;--card:#fff;--text:#1e293b;--sub:#64748b;--line:#e6ecf5;--primary:#2563eb}
*{box-sizing:border-box}
body{font-family:"Microsoft YaHei",system-ui,sans-serif;margin:0;background:var(--bg);color:var(--text);line-height:1.6}
.hero{background:linear-gradient(135deg,#1e3a8a,#2563eb);color:#fff;padding:34px 40px 58px}
.hero h1{font-size:28px;margin:0 0 8px;letter-spacing:.5px}
.hero .meta{opacity:.85;font-size:13px}
.wrap{max-width:1440px;margin:0 auto;padding:0 32px 60px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin-top:-38px;position:relative;z-index:2}
.card{background:var(--card);border-radius:14px;padding:16px 20px;box-shadow:0 4px 18px rgba(15,23,42,.08);border-left:4px solid var(--c,var(--primary))}
.card .n{font-size:30px;font-weight:700;line-height:1.2;color:var(--c,var(--primary))}
.card .t{font-size:14px;font-weight:600;margin-top:4px}
.card .d{font-size:11px;color:var(--sub);margin-top:2px}
.notice{background:#fff;border:1px solid var(--line);border-left:4px solid #f59e0b;border-radius:10px;padding:14px 18px;margin:24px 0 18px;font-size:13px;color:#475569}
.notice b{color:#b45309}
.toolbar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:14px}
.toolbar input{flex:1;min-width:220px;border:1px solid var(--line);border-radius:10px;padding:10px 14px;font-size:13px;font-family:inherit;outline:none;background:#fff}
.toolbar input:focus{border-color:var(--primary);box-shadow:0 0 0 3px rgba(37,99,235,.1)}
.filters{display:flex;gap:6px;flex-wrap:wrap}
.filters button{border:1px solid var(--line);background:#fff;color:var(--sub);border-radius:18px;padding:7px 14px;font-size:12px;cursor:pointer;font-family:inherit}
.filters button.on{background:var(--primary);border-color:var(--primary);color:#fff;font-weight:600}
.tbox{background:#fff;border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:0 2px 10px rgba(15,23,42,.04)}
table{border-collapse:collapse;width:100%;font-size:13px}
th{background:#f8fafc;text-align:left;padding:12px 14px;font-weight:600;color:var(--sub);border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:11px 14px;border-bottom:1px solid #f1f5f9;vertical-align:top}
tbody tr{cursor:pointer}
tbody tr:hover{background:#f8fbff}
.f{color:var(--sub);font-size:11px;font-weight:400}
.tag{display:inline-block;padding:2px 10px;border-radius:10px;font-size:12px;white-space:nowrap;font-weight:600}
.h{background:#fee2e2;color:#b91c1c}.m{background:#ffedd5;color:#c2410c}
.u{background:#fef9c3;color:#a16207}.n{background:#f1f5f9;color:#475569}.g{background:#dcfce7;color:#15803d}
.cp{max-width:340px;max-height:2.9em;overflow:hidden;color:#475569;font-size:12px}
tr.open .cp{max-height:none;white-space:pre-wrap}
.alt{color:#2563eb;font-size:12px}
.foot{text-align:center;color:var(--sub);font-size:12px;padding:24px 0 0}
@media(max-width:760px){.wrap{padding:0 14px 40px}.hero{padding:24px 18px 50px}th,td{padding:8px}}
@media print{.toolbar{display:none}.hero{background:#1e3a8a!important;-webkit-print-color-adjust:exact}}
'@
  $js = @'
(function(){
 var q=document.getElementById('q'),rows=[].slice.call(document.querySelectorAll('#t tbody tr')),f='全部';
 function apply(){
  rows.forEach(function(r){
   var ok=(f==='全部'||r.getAttribute('data-r')===f)&&(!q.value||r.textContent.toLowerCase().indexOf(q.value.toLowerCase())>=0);
   r.style.display=ok?'':'none';
  });
 }
 q.addEventListener('input',apply);
 document.querySelectorAll('.filters button').forEach(function(b){
  b.addEventListener('click',function(){
   document.querySelectorAll('.filters button').forEach(function(x){x.classList.remove('on')});
   b.classList.add('on');f=b.getAttribute('data-f');apply();
  });
 });
 rows.forEach(function(r){r.addEventListener('click',function(){r.classList.toggle('open')})});
})();
'@
  $sb = New-Object System.Text.StringBuilder
  $add = { param($s) [void]$sb.AppendLine($s) }
  $esc = { param($t) ([string]$t) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
  & $add '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>字体版权自查报告</title>'
  & $add ('<style>' + $css + '</style></head><body>')
  & $add '<div class="hero"><h1>字体版权自查报告</h1>'
  & $add ("<div class='meta'>扫描时间：{0}　|　扫描范围：本机已安装字体　|　共 {1} 个字体文件</div>" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'),$total)
  & $add '</div><div class="wrap"><div class="cards">'
  foreach ($x in $lv) {
    $c = @($rows | Where-Object { $_.判定 -eq $x.N }).Count
    & $add ("<div class='card' style='--c:{0}'><div class='n'>{1}</div><div class='t'>{2}</div><div class='d'>{3}</div></div>" -f $x.C,$c,$x.N,$x.D)
  }
  & $add '</div>'
  & $add '<div class="notice"><b>⚠ 商用前请核对：</b>判定为「高风险」的字体出现在海报、详情页、公众号、包装、客户提案或商标 LOGO 等对外物料前，须取得字库厂商商业授权；仅本机显示、个人打印通常不构成商业发布。本工具读取字体文件内嵌版权字段，改名、子集化、转曲、栅格化后无法识别，结论<b>仅供初筛，不构成法律意见</b>，最终以字库厂商授权为准。点击任意行可展开完整版权声明。</div>'
  & $add '<div class="toolbar"><input id="q" placeholder="搜索字体名 / 文件名 / 厂商版权…"><div class="filters">'
  foreach ($n in @('全部','高风险','中风险','待核实','常规','可商用')) {
    $on = if ($n -eq '全部') { ' class="on"' } else { '' }
    & $add ("<button{0} data-f='{1}'>{1}</button>" -f $on,$n)
  }
  & $add '</div></div><div class="tbox"><table id="t"><thead><tr><th>#</th><th>字体名</th><th>判定</th><th>厂商 / 版权声明</th><th>说明</th><th>建议替代</th></tr></thead><tbody>'
  $order = @{ '高风险'=0; '中风险'=1; '待核实'=2; '常规'=3; '可商用'=4 }
  foreach ($r in ($rows | Sort-Object @{ Expression={ $order[$_.判定] } },字体名)) {
    $cls = @{ '高风险'='h'; '中风险'='m'; '可商用'='g'; '常规'='n' }[$r.判定]
    if (-not $cls) { $cls = 'u' }
    $txt = (& $esc ("$($r.厂商版权) $($r.版权声明)".Trim()))
    if (-not $txt) { $txt = '（文件内无版权字段）' }
    & $add ("<tr data-r='{0}'><td>{1}</td><td><b>{2}</b><br><span class='f'>{3}</span></td><td><span class='tag {4}'>{0}</span></td><td class='cp'>{5}</td><td class='f'>{6}</td><td class='alt'>{7}</td></tr>" -f $r.判定,$r.序号,(& $esc $r.字体名),(& $esc $r.文件名),$cls,$txt,(& $esc $r.说明),(& $esc $r.建议替代))
  }
  & $add '</tbody></table></div>'
  & $add '<div class="foot">本工具仅供字体版权初筛 · 最终授权以字库厂商为准</div>'
  & $add ('</div><script>' + $js + '</script></body></html>')
  [System.IO.File]::WriteAllText($outPath,$sb.ToString(),(New-Object System.Text.UTF8Encoding($false)))
}

# ================= 界面 =================
$C = @{
  bg      = [System.Drawing.ColorTranslator]::FromHtml('#F6F8FC')
  card    = [System.Drawing.Color]::White
  line    = [System.Drawing.ColorTranslator]::FromHtml('#E6ECF5')
  text    = [System.Drawing.ColorTranslator]::FromHtml('#1E293B')
  sub     = [System.Drawing.ColorTranslator]::FromHtml('#64748B')
  primary = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
  priH    = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
  soft    = [System.Drawing.ColorTranslator]::FromHtml('#EFF6FF')
}
$RiskStyle = @{
  '高风险' = @{ fg=[System.Drawing.ColorTranslator]::FromHtml('#B91C1C'); bg=[System.Drawing.ColorTranslator]::FromHtml('#FEF2F2'); bar=[System.Drawing.ColorTranslator]::FromHtml('#EF4444') }
  '中风险' = @{ fg=[System.Drawing.ColorTranslator]::FromHtml('#C2410C'); bg=[System.Drawing.ColorTranslator]::FromHtml('#FFF7ED'); bar=[System.Drawing.ColorTranslator]::FromHtml('#F97316') }
  '待核实' = @{ fg=[System.Drawing.ColorTranslator]::FromHtml('#A16207'); bg=[System.Drawing.ColorTranslator]::FromHtml('#FEFCE8'); bar=[System.Drawing.ColorTranslator]::FromHtml('#EAB308') }
  '常规'   = @{ fg=[System.Drawing.ColorTranslator]::FromHtml('#475569'); bg=[System.Drawing.ColorTranslator]::FromHtml('#F1F5F9'); bar=[System.Drawing.ColorTranslator]::FromHtml('#94A3B8') }
  '可商用' = @{ fg=[System.Drawing.ColorTranslator]::FromHtml('#15803D'); bg=[System.Drawing.ColorTranslator]::FromHtml('#F0FDF4'); bar=[System.Drawing.ColorTranslator]::FromHtml('#22C55E') }
}
$RiskOrder = @{ '高风险'=0; '中风险'=1; '待核实'=2; '常规'=3; '可商用'=4 }

# ================= 自定义判定 / 白名单 =================
$wlPath = Join-Path $scriptDir 'whitelist.json'
$script:WhiteList = @{}
function Get-WlKey($r) {
  return ("$($r.字体名)|$($r.文件名)" -replace '\s+','')
}
function Load-WhiteList {
  $script:WhiteList = @{}
  if (Test-Path $wlPath) {
    try {
      $items = [IO.File]::ReadAllText($wlPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
      foreach ($it in $items) { if ($it.key -and $it.level) { $script:WhiteList[[string]$it.key] = $it } }
    } catch { }
  }
}
function Save-WhiteList {
  try {
    $arr = @($script:WhiteList.Values)
    $json = $arr | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($wlPath,$json,(New-Object System.Text.UTF8Encoding($false)))
  } catch {
    [System.Windows.Forms.MessageBox]::Show("保存自定义判定失败：$($_.Exception.Message)",'错误')
  }
}
# 扫描后用白名单覆盖判定；level='自动' 表示恢复机器判定
function Apply-WhiteList {
  $log = New-Object System.Collections.Generic.List[object]
  foreach ($r in $script:Rows) {
    if (-not $r.PSObject.Properties['原判定']) { $r | Add-Member -NotePropertyName '原判定' -NotePropertyValue $r.判定 }
    if (-not $r.PSObject.Properties['原说明']) { $r | Add-Member -NotePropertyName '原说明' -NotePropertyValue $r.说明 }
    $k = Get-WlKey $r
    if ($script:WhiteList.ContainsKey($k)) {
      $e = $script:WhiteList[$k]
      if ([string]$e.level -eq '自动') {
        $r.判定 = $r.原判定; $r.说明 = $r.原说明
      } else {
        $r.判定 = [string]$e.level
        $r.说明 = "【自定义】$([string]$e.note)"; $r | Add-Member -NotePropertyName '自定义' -NotePropertyValue $true -Force
      }
    }
  }
}

# 统一入口：扫描 + 应用自定义判定
function Get-RowsWithOverride([scriptblock]$OnProgress) {
  Load-Rules
  Load-WhiteList
  if ($OnProgress) { $script:Rows = Get-FontRows -OnProgress $OnProgress }
  else { $script:Rows = Get-FontRows }
  Apply-WhiteList
  return $script:Rows
}

# ================= 受保护的删除到回收站 =================
function Remove-FontToRecycle($r) {
  $path = [string]$r.路径
  if (-not $path -or -not (Test-Path $path)) {
    [System.Windows.Forms.MessageBox]::Show('字体文件不存在，可能已被移动或删除。','无法删除'); return $false
  }
  $sysDir = Join-Path $env:WINDIR 'Fonts'
  $isSystem = $path.StartsWith($sysDir,[System.StringComparison]::OrdinalIgnoreCase)
  $msg = "即将把下面的字体文件移到回收站（可恢复）：`n`n$path`n`n字体名：$($r.字体名)`n"
  if ($isSystem) { $msg += "`n⚠ 这是 Windows 系统字体目录，删除可能影响系统显示，请谨慎！`n" }
  $msg += "`n确认删除吗？"
  $ans = [System.Windows.Forms.MessageBox]::Show($msg,'删除到回收站 · 二次确认',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
  if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,'OnlyErrorDialogs','SendToRecycleBin')
    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t已移入回收站`t$($r.字体名)`t$path"
    [IO.File]::AppendAllText((Join-Path $scriptDir 'delete-log.txt'),$logLine+"`r`n",(New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    [System.Windows.Forms.MessageBox]::Show("删除失败：$($_.Exception.Message)`n`n可能原因：文件正被占用，或没有足够权限。",'删除失败')
    return $false
  }
}

# 删除后统一重新扫描刷新（表格按钮与详情窗口按钮共用）
function Delete-And-Refresh($r) {
  if (-not (Remove-FontToRecycle $r)) { return $false }
  $btnScan.Enabled=$false; $btnExport.Enabled=$false; $btnScan.Text='扫描中…'
  $statusLeft.Text='字体已删除，正在刷新列表…'; [System.Windows.Forms.Application]::DoEvents()
  try {
    $script:Rows=Get-RowsWithOverride
    $btnExport.Enabled=$true; $statusLeft.Text="字体已删除并移入回收站，当前共 $($script:Rows.Count) 个字体"
  } finally {
    $btnScan.Enabled=$true; $btnScan.Text='重新扫描'
  }
  Update-Grid
  return $true
}

function New-RoundRegion([int]$w, [int]$h, [int]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = [Math]::Max(2, $r * 2)
  $wd = $w - $d
  $hd = $h - $d
  $p.AddArc(0,0,$d,$d,180,90); $p.AddArc($wd,0,$d,$d,270,90)
  $p.AddArc($wd,$hd,$d,$d,0,90); $p.AddArc(0,$hd,$d,$d,90,90)
  $p.CloseFigure()
  return New-Object System.Drawing.Region($p)
}
function Add-Tip($ctrl, [string]$text) {
  $t = New-Object System.Windows.Forms.ToolTip
  $t.SetToolTip($ctrl, $text); $t.InitialDelay = 200
  return $t
}

# 抗锯齿圆角：用 GraphicsPath 自绘，替代会锯齿的 Control.Region
$script:RoundStyle = @{}
function New-RoundPath([int]$w, [int]$h, [int]$r, [double]$inset = 0.5) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  # 填充路径 inset=0.5；描边路径 inset=1.5，让 1px 笔完整落在客户区内，底/右边不被裁
  $l = $inset
  $t = $inset
  $rt = $w - $inset
  $bt = $h - $inset
  $d = $r * 2
  if ($d -gt ($rt - $l)) { $d = $rt - $l }
  if ($d -gt ($bt - $t)) { $d = $bt - $t }
  if ($d -lt 1) { $d = 1 }
  $p.AddArc($l,$t,$d,$d,180,90)
  $p.AddArc($rt-$d,$t,$d,$d,270,90)
  $p.AddArc($rt-$d,$bt-$d,$d,$d,0,90)
  $p.AddArc($l,$bt-$d,$d,$d,90,90)
  $p.CloseFigure()
  return $p
}
function Set-RoundButton {
  param($ctrl, [string]$name, $bg, $fg, [int]$r, $border, [bool]$bold)
  $ctrl.Name = $name
  $script:RoundStyle[$name] = @{ BG=$bg; FG=$fg; R=$r; Border=$border; Bold=$bold }
  $ctrl.BackColor = [System.Drawing.Color]::Transparent
  $ctrl.ForeColor = [System.Drawing.Color]::Transparent
  if ($ctrl -is [System.Windows.Forms.Button]) {
    $ctrl.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $ctrl.FlatAppearance.BorderSize = 0
  }
  $ctrl.Add_Paint({
    param($s,$e)
    $st = $script:RoundStyle[$s.Name]
    if (-not $st) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w0 = $s.ClientSize.Width
    $h0 = $s.ClientSize.Height
    $pbg = $C.card
    if ($s.Parent -and $s.Parent.BackColor) { $pbg = $s.Parent.BackColor }
    $pb = New-Object System.Drawing.SolidBrush($pbg)
    $g.FillRectangle($pb,0,0,$w0,$h0)
    $pb.Dispose()
    $path = New-RoundPath $w0 $h0 $st.R
    $bg0 = $st.BG
    $fg0 = $st.FG
    if (-not $s.Enabled) {
      $bg0 = [System.Drawing.ColorTranslator]::FromHtml('#E5E6EB')
      $fg0 = [System.Drawing.ColorTranslator]::FromHtml('#9AA3B0')
    }
    $br = New-Object System.Drawing.SolidBrush($bg0)
    $g.FillPath($br,$path)
    $br.Dispose()
    if ($st.Border) {
      # 描边用内缩 1px 的路径，避免 1px 笔一半落在客户区外导致下/右边线消失
      $pen = New-Object System.Drawing.Pen($st.Border)
      $bp = New-RoundPath $w0 $h0 $st.R 1.5
      $g.DrawPath($pen,$bp)
      $bp.Dispose(); $pen.Dispose()
    }
    $fs = [System.Drawing.FontStyle]::Regular
    if ($st.Bold) { $fs = [System.Drawing.FontStyle]::Bold }
    $ft = New-Object System.Drawing.Font('Microsoft YaHei UI',9,$fs)
    $fb = New-Object System.Drawing.SolidBrush($fg0)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rc = New-Object System.Drawing.RectangleF(0,0,$w0,$h0)
    $g.DrawString($s.Text,$ft,$fb,$rc,$sf)
    $fb.Dispose(); $ft.Dispose(); $path.Dispose()
  })
}
function Update-RoundButton {
  param($ctrl, $bg, $fg, [bool]$bold, $border)
  $st = $script:RoundStyle[$ctrl.Name]
  if (-not $st) { return }
  if ($PSBoundParameters.ContainsKey('bg')) { $st.BG = $bg }
  if ($PSBoundParameters.ContainsKey('fg')) { $st.FG = $fg }
  if ($PSBoundParameters.ContainsKey('bold')) { $st.Bold = $bold }
  if ($PSBoundParameters.ContainsKey('border')) { $st.Border = $border }
  $ctrl.Invalidate()
}
# Panel/Label 的圆角背景自绘（不接管文字，文字由子控件/自身绘制）
function Set-RoundSurface {
  param($ctrl, [string]$name, $bg, [int]$r, $border, $drawText, [string]$textColor)
  $ctrl.Name = $name
  $script:RoundStyle[$name] = @{ BG=$bg; FG=$null; R=$r; Border=$border; Bold=$false; Surface=$true; DrawText=$drawText; TextColor=$textColor }
  $ctrl.BackColor = [System.Drawing.Color]::Transparent
  $ctrl.Add_Paint({
    param($s,$e)
    $st = $script:RoundStyle[$s.Name]
    if (-not $st) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w0 = $s.ClientSize.Width
    $h0 = $s.ClientSize.Height
    $pbg = $C.card
    if ($s.Parent -and $s.Parent.BackColor) { $pbg = $s.Parent.BackColor }
    $pb = New-Object System.Drawing.SolidBrush($pbg)
    $g.FillRectangle($pb,0,0,$w0,$h0)
    $pb.Dispose()
    $path = New-RoundPath $w0 $h0 $st.R
    $br = New-Object System.Drawing.SolidBrush($st.BG)
    $g.FillPath($br,$path)
    $br.Dispose()
    if ($st.Border) {
      $pen = New-Object System.Drawing.Pen($st.Border)
      $bp = New-RoundPath $w0 $h0 $st.R 1.5
      $g.DrawPath($pen,$bp)
      $bp.Dispose(); $pen.Dispose()
    }
    $path.Dispose()
    if ($st.DrawText -and $s.Text) {
      $fc = $C.text
      if ($st.TextColor) { $fc = [System.Drawing.Color]::FromName($st.TextColor) }
      $fb = New-Object System.Drawing.SolidBrush($fc)
      $sf = New-Object System.Drawing.StringFormat
      $sf.Alignment = [System.Drawing.StringAlignment]::Center
      $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
      $rc = New-Object System.Drawing.RectangleF(0,0,$w0,$h0)
      $g.DrawString($s.Text,$s.Font,$fb,$rc,$sf)
      $fb.Dispose()
    }
  })
}

$script:Rows = @()
$script:NeedRefresh = $false
$script:NeedRescan = $false
$script:Filter = '全部'
$script:SortCol = '判定'
$script:SortAsc = $true
$script:Tips = @()

$form = New-Object System.Windows.Forms.Form
$form.Text = '字体版权自查'
$form.Size = New-Object System.Drawing.Size(1180, 780)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.bg
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$cw = [int]$form.ClientSize.Width
$ch = [int]$form.ClientSize.Height

# ---------- 顶部 ----------
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0,0)
$header.Size = New-Object System.Drawing.Size($cw,90)
$header.BackColor = $C.card
$form.Controls.Add($header)

$logo = New-Object System.Windows.Forms.Label
$logo.Text = '字'; $logo.Size = New-Object System.Drawing.Size(46,46)
$logo.Location = New-Object System.Drawing.Point(30,22)
$logo.ForeColor = [System.Drawing.Color]::White
$logo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',17,[System.Drawing.FontStyle]::Bold)
$logo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
Set-RoundSurface $logo 'logo' $C.primary 12 $null $true 'White'
$header.Controls.Add($logo)

$title = New-Object System.Windows.Forms.Label
$title.Text = '字体版权自查'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',20,[System.Drawing.FontStyle]::Bold)
$title.ForeColor = $C.text
$title.Location = New-Object System.Drawing.Point(90,19); $title.AutoSize = $true
$header.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = '扫描本机已装字体 · 商用风险初筛 · 结论不构成法律意见'
$sub.ForeColor = $C.sub; $sub.Location = New-Object System.Drawing.Point(92,58); $sub.AutoSize = $true
$header.Controls.Add($sub)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '开始扫描'; $btnScan.Size = New-Object System.Drawing.Size(112,40)
$btnScanX = $cw - 264
$btnScan.Location = New-Object System.Drawing.Point($btnScanX,25)
$btnScan.Anchor = 'Top,Right'
$btnScan.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9,[System.Drawing.FontStyle]::Bold)
$btnScan.Cursor = [System.Windows.Forms.Cursors]::Hand
Set-RoundButton $btnScan 'btnScan' $C.primary ([System.Drawing.Color]::White) 10 $null $true
$header.Controls.Add($btnScan)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = '导出报告'; $btnExport.Size = New-Object System.Drawing.Size(112,40)
$btnExportX = $cw - 140
$btnExport.Location = New-Object System.Drawing.Point($btnExportX,25)
$btnExport.Anchor = 'Top,Right'
$btnExport.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$btnExport.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnExport.Enabled = $false
Set-RoundButton $btnExport 'btnExport' $C.card $C.text 10 $C.line $false
$header.Controls.Add($btnExport)

# ---------- 筛选条 ----------
$bar = New-Object System.Windows.Forms.Panel
$bar.Location = New-Object System.Drawing.Point(0,90)
$bar.Size = New-Object System.Drawing.Size($cw,62)
$bar.BackColor = $C.card
$form.Controls.Add($bar)
$bar.Add_Paint({
  param($s,$e)
  $p = New-Object System.Drawing.Pen($C.line)
  $y = $s.ClientSize.Height - 1
  $e.Graphics.DrawLine($p,0,$y,$s.ClientSize.Width,$y); $p.Dispose()
})

$searchHost = New-Object System.Windows.Forms.Panel
$searchHost.Location = New-Object System.Drawing.Point(30,15)
$searchHost.Size = New-Object System.Drawing.Size(260,32)
Set-RoundSurface $searchHost 'searchHost' ([System.Drawing.ColorTranslator]::FromHtml('#F1F5F9')) 16 $null
$bar.Controls.Add($searchHost)

$searchIcon = New-Object System.Windows.Forms.Label
$searchIcon.Text = [char]0x2315
$searchIcon.Font = New-Object System.Drawing.Font('Segoe UI Symbol',14)
$searchIcon.ForeColor = $C.sub
$searchIcon.Location = New-Object System.Drawing.Point(12,5)
$searchIcon.AutoSize = $true
$searchHost.Controls.Add($searchIcon)

$txt = New-Object System.Windows.Forms.TextBox
$txt.BorderStyle = 'None'; $txt.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F1F5F9')
$txt.ForeColor = $C.sub; $txt.Text = '搜索字体名 / 文件名 / 厂商'
$txt.Location = New-Object System.Drawing.Point(38,7); $txt.Size = New-Object System.Drawing.Size(212,20)
$txt.Add_GotFocus({ if ($txt.Text -eq '搜索字体名 / 文件名 / 厂商') { $txt.Text=''; $txt.ForeColor=$C.text } })
$txt.Add_LostFocus({ if ($txt.Text.Trim() -eq '') { $txt.Text='搜索字体名 / 文件名 / 厂商'; $txt.ForeColor=$C.sub } })
$txt.Add_TextChanged({ Update-Grid })
$searchHost.Controls.Add($txt)

$script:Chips = @{}
$cx = 310
foreach ($name in @('全部','高风险','中风险','待核实','常规','可商用')) {
  $w = if ($name -eq '全部') { 84 } elseif ($name -in '高风险','中风险','待核实','可商用') { 92 } else { 80 }
  $chip = New-Object System.Windows.Forms.Button
  $chip.Text = $name; $chip.Tag = $name; $chip.Size = New-Object System.Drawing.Size($w,30)
  $chip.Location = New-Object System.Drawing.Point($cx,16)
  $chip.Cursor = [System.Windows.Forms.Cursors]::Hand
  Set-RoundButton $chip "chip_$name" $C.card $C.sub 15 $C.line $false
  $chip.Add_Click({ $script:Filter=[string]$this.Tag; Update-Chips; Update-Grid })
  $bar.Controls.Add($chip); $script:Chips[$name] = $chip
  $cx += $w + 8
}

# 规则设置入口：高级功能，默认隐藏；settings.json 中 showRuleButton=true 才显示
# 无论是否显示，按 Ctrl+R 都能打开规则文件
$settingsPath = Join-Path $scriptDir 'settings.json'
function Open-Rules {
  if (-not (Test-Path $rulesPath)) {
    [System.Windows.Forms.MessageBox]::Show("规则文件不存在：`n$rulesPath",'提示'); return
  }
  try { [System.Diagnostics.Process]::Start('notepad.exe',$rulesPath) }
  catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)",'错误') }
}
$showRuleButton = $false
if (Test-Path $settingsPath) {
  try {
    $st = [IO.File]::ReadAllText($settingsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($st.PSObject.Properties['showRuleButton']) { $showRuleButton = [bool]$st.showRuleButton }
  } catch {}
}
if ($showRuleButton) {
  $btnRules = New-Object System.Windows.Forms.Button
  $btnRules.Text = '规则设置'; $btnRules.Size = New-Object System.Drawing.Size(88,30)
  $btnRulesX = $cw - 104
  $btnRules.Location = New-Object System.Drawing.Point($btnRulesX,16)
  $btnRules.Anchor = 'Top,Right'; $btnRules.Cursor = [System.Windows.Forms.Cursors]::Hand
  Set-RoundButton $btnRules 'btnRules' $C.soft $C.primary 15 $C.line $false
  $btnRules.Add_Click({ Open-Rules })
  $bar.Controls.Add($btnRules)
}
$form.KeyPreview = $true
$form.Add_KeyDown({
  if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::R) { Open-Rules }
})

$fnTip = Add-Tip $btnScan '重新读取本机字体文件并刷新列表'
$exTip = Add-Tip $btnExport '导出 HTML 报告 + CSV 清单到指定文件夹'

function Update-Chips {
  foreach ($k in $script:Chips.Keys) {
    $chip = $script:Chips[$k]
    if ($k -eq $script:Filter) {
      if ($k -eq '全部') { Update-RoundButton $chip -bg $C.primary -fg ([System.Drawing.Color]::White) -bold $true -border $null }
      else { Update-RoundButton $chip -bg $RiskStyle[$k].bg -fg $RiskStyle[$k].fg -bold $true -border $null }
    } else {
      Update-RoundButton $chip -bg $C.card -fg $C.sub -bold $false -border $C.line
    }
  }
}
Update-Chips

# ---------- 表格 ----------
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16,166)
$gridW = $cw - 32
$gridH = $ch - 222
$grid.Size = New-Object System.Drawing.Size($gridW,$gridH)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.BackgroundColor = $C.card; $grid.BorderStyle = 'None'
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.GridColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F8')
$grid.RowHeadersVisible = $false; $grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersHeight = 36; $grid.ColumnHeadersBorderStyle = 'None'
$grid.RowTemplate.Height = 40; $grid.AutoSizeColumnsMode = 'Fill'
$grid.ShowCellToolTips = $true
$grid.ColumnHeadersDefaultCellStyle.BackColor = $C.card
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $C.sub
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(12,0,0,0)
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $C.card
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $C.sub
$grid.DefaultCellStyle.BackColor = $C.card; $grid.DefaultCellStyle.ForeColor = $C.text
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.ColorTranslator]::FromHtml('#EFF6FF')
$grid.DefaultCellStyle.SelectionForeColor = $C.text
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(12,0,6,0)
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FAFCFF')

function New-Col($n,$t,$w) {
  $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $c.Name=$n; $c.HeaderText=$t; $c.FillWeight=$w
  $c.SortMode = 'NotSortable'
  return $c
}
$colFont = New-Col '字体名' '字体名' 120
$colFont.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9,[System.Drawing.FontStyle]::Bold)
$colRisk = New-Col '判定' '判定' 66
$colFile = New-Col '文件名' '文件名' 100
$colVendor = New-Col '厂商' '厂商 / 版权' 168
$colVendor.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
$colVendor.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',8)
$colAlt = New-Col '建议' '建议替代' 118
$colNote = New-Col '说明' '说明' 150
$colNote.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',8)
$colOp = New-Col '操作' '' 60
$colOp.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
[void]$grid.Columns.AddRange($colFont,$colRisk,$colFile,$colVendor,$colAlt,$colNote,$colOp)
$form.Controls.Add($grid)

$grid.Add_CellPainting({
  param($s,$e)
  if ($e.RowIndex -lt 0) { return }
  $colName = $grid.Columns[$e.ColumnIndex].Name
  if ($colName -eq '操作') {
    $e.PaintBackground($e.CellBounds,$true)
    $risk = [string]$grid.Rows[$e.RowIndex].Cells['判定'].Value
    if ($risk -eq '高风险') {
      $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $f = New-Object System.Drawing.Font('Microsoft YaHei UI',8,[System.Drawing.FontStyle]::Bold)
      $txt2 = '删除'
      $tw2 = [int][System.Windows.Forms.TextRenderer]::MeasureText($txt2,$f).Width
      $bw = $tw2 + 24
      $bh = 24
      $bx = $e.CellBounds.X + [int](($e.CellBounds.Width - $bw)/2)
      $by = $e.CellBounds.Y + [int](($e.CellBounds.Height - $bh)/2)
      $rect = New-Object System.Drawing.RectangleF($bx,$by,$bw,$bh)
      $p = New-Object System.Drawing.Drawing2D.GraphicsPath
      $d2 = 12
      $rx2 = $rect.Right - $d2
      $by2 = $rect.Bottom - $d2
      $p.AddArc($rect.X,$rect.Y,$d2,$d2,180,90); $p.AddArc($rx2,$rect.Y,$d2,$d2,270,90)
      $p.AddArc($rx2,$by2,$d2,$d2,0,90); $p.AddArc($rect.X,$by2,$d2,$d2,90,90)
      $p.CloseFigure()
      $br2 = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#FEE2E2'))
      $g.FillPath($br2,$p)
      $pen2 = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml('#FCA5A5'))
      $g.DrawPath($pen2,$p)
      $tb2 = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#B91C1C'))
      $sf2 = New-Object System.Drawing.StringFormat
      $sf2.Alignment = [System.Drawing.StringAlignment]::Center
      $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
      $g.DrawString($txt2,$f,$tb2,$rect,$sf2)
      $br2.Dispose(); $pen2.Dispose(); $tb2.Dispose(); $p.Dispose(); $f.Dispose()
    }
    $e.Handled = $true
    return
  }
  if ($colName -ne '判定') { return }
  $e.PaintBackground($e.CellBounds,$true)
  $val = [string]$grid.Rows[$e.RowIndex].Cells['判定'].Value
  $st = $RiskStyle[$val]
  if ($st) {
    $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $f = New-Object System.Drawing.Font('Microsoft YaHei UI',9,[System.Drawing.FontStyle]::Bold)
    $tw = [int][System.Windows.Forms.TextRenderer]::MeasureText($val,$f).Width
    $rx0 = $e.CellBounds.X + 8
    $ry0 = $e.CellBounds.Y + [int](($e.CellBounds.Height - 24) / 2)
    $rw0 = $tw + 20
    $rect = New-Object System.Drawing.RectangleF($rx0,$ry0,$rw0,24)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d=22
    $rx = $rect.Right - $d
    $by = $rect.Bottom - $d
    $p.AddArc($rect.X,$rect.Y,$d,$d,180,90); $p.AddArc($rx,$rect.Y,$d,$d,270,90)
    $p.AddArc($rx,$by,$d,$d,0,90); $p.AddArc($rect.X,$by,$d,$d,90,90)
    $p.CloseFigure()
    $br = New-Object System.Drawing.SolidBrush($st.bg); $g.FillPath($br,$p)
    $tb = New-Object System.Drawing.SolidBrush($st.fg)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($val,$f,$tb,$rect,$sf)
    $br.Dispose(); $tb.Dispose(); $p.Dispose(); $f.Dispose()
  }
  $e.Handled = $true
})

$grid.Add_RowPostPaint({
  param($s,$e)
  if ($e.RowIndex -lt 0) { return }
  $st = $RiskStyle[[string]$grid.Rows[$e.RowIndex].Cells['判定'].Value]
  if (-not $st) { return }
  $ry = $e.RowBounds.Top + 2
  $rh = $e.RowBounds.Height - 4
  $r = New-Object System.Drawing.Rectangle(0,$ry,4,$rh)
  $br = New-Object System.Drawing.SolidBrush($st.bar)
  $e.Graphics.FillRectangle($br,$r); $br.Dispose()
})

$grid.Add_Paint({
  param($s,$e)
  $p = New-Object System.Drawing.Pen($C.line)
  $e.Graphics.DrawLine($p,0,$grid.ColumnHeadersHeight-1,$grid.Width,$grid.ColumnHeadersHeight-1)
  $p.Dispose()
})

function Shorten([string]$s, [int]$n) {
  if (-not $s) { return '' }
  $t = $s -replace '\s+',' '
  if ($t.Length -le $n) { return $t }
  return $t.Substring(0,$n) + '…'
}
function Update-Grid {
  if (-not $script:Rows -or $script:Rows.Count -eq 0) { return }
  $kw = $txt.Text.Trim()
  if ($kw -eq '搜索字体名 / 文件名 / 厂商') { $kw = '' }
  $show = $script:Rows
  if ($script:Filter -ne '全部') { $show = $show | Where-Object { $_.判定 -eq $script:Filter } }
  if ($kw) { $show = $show | Where-Object { $_.字体名 -like "*$kw*" -or $_.文件名 -like "*$kw*" -or "$($_.厂商版权) $($_.版权声明)" -like "*$kw*" } }
  $show = $show | Sort-Object @{ Expression={ $RiskOrder[$_.判定] } },字体名
  $grid.SuspendLayout(); $grid.Rows.Clear()
  foreach ($r in $show) {
    $vendor = ("$($r.厂商版权) $($r.版权声明)").Trim()
    if (-not $vendor) { $vendor = '（文件内无版权字段）' }
    $i = $grid.Rows.Add($r.字体名,$r.判定,$r.文件名,(Shorten $vendor 56),$r.建议替代,(Shorten $r.说明 34))
    $grid.Rows[$i].Tag = $r
    $grid.Rows[$i].Cells['厂商'].ToolTipText = $vendor
    $grid.Rows[$i].Cells['字体名'].ToolTipText = $r.字体名
    $grid.Rows[$i].Cells['说明'].ToolTipText = $r.说明
    $grid.Rows[$i].Cells['建议'].ToolTipText = $r.建议替代
  }
  $grid.ResumeLayout(); Update-Stats
}
function Update-Stats {
  if ($script:Rows.Count -eq 0) { return }
  $parts = @()
  foreach ($k in '高风险','中风险','待核实','常规','可商用') {
    $c = @($script:Rows | Where-Object { $_.判定 -eq $k }).Count
    if ($c -gt 0) { $parts += "$k $c" }
  }
  $sub.Text = "已扫描 $($script:Rows.Count) 个字体　·　初筛结果，仅供核对授权参考"
  $statusLeft.Text = "共 $($script:Rows.Count) 个字体文件　·　当前显示 $($grid.Rows.Count) 条"
  foreach ($k in $script:Chips.Keys) {
    $chip = $script:Chips[$k]
    if ($k -eq '全部') { $chip.Text = "全部 $($script:Rows.Count)" }
    else { $chip.Text = "$k $(@($script:Rows | Where-Object { $_.判定 -eq $k }).Count)" }
  }
}

# ---------- 底部 ----------
$footer = New-Object System.Windows.Forms.Panel
$footerY = $ch - 42
$footer.Location = New-Object System.Drawing.Point(0,$footerY)
$footer.Size = New-Object System.Drawing.Size($cw,42)
$footer.Anchor = 'Bottom,Left,Right'; $footer.BackColor = $C.card
$form.Controls.Add($footer)
$footer.Add_Paint({
  param($s,$e)
  $p = New-Object System.Drawing.Pen($C.line)
  $e.Graphics.DrawLine($p,0,0,$footer.Width,0); $p.Dispose()
})
$statusLeft = New-Object System.Windows.Forms.Label
$statusLeft.Text = '点右上角「开始扫描」生成本机字体清单'
$statusLeft.ForeColor = $C.sub
$statusLeft.Location = New-Object System.Drawing.Point(30,12); $statusLeft.AutoSize = $true
$footer.Controls.Add($statusLeft)
$barProg = New-Object System.Windows.Forms.ProgressBar
$barProg.Size = New-Object System.Drawing.Size(180,10)
$progX = $cw - 520
$barProg.Location = New-Object System.Drawing.Point($progX,16)
$barProg.Anchor = 'Top,Right'; $barProg.Style = 'Continuous'
$barProg.Visible = $false
$footer.Controls.Add($barProg)
$statusRight = New-Object System.Windows.Forms.Label
$statusRight.Text = '⚠ 高风险字体商用前须授权  ·  双击查看完整版权信息'
$statusRight.ForeColor = $C.sub
$srX = $cw - 330
$statusRight.Location = New-Object System.Drawing.Point($srX,12)
$statusRight.Anchor = 'Top,Right'; $statusRight.AutoSize = $true
$footer.Controls.Add($statusRight)

# ---------- 交互 ----------
$btnScan.Add_MouseEnter({ Update-RoundButton $btnScan -bg $C.priH })
$btnScan.Add_MouseLeave({ Update-RoundButton $btnScan -bg $C.primary })
$btnExport.Add_MouseEnter({ if ($btnExport.Enabled) { Update-RoundButton $btnExport -bg $C.soft } })
$btnExport.Add_MouseLeave({ Update-RoundButton $btnExport -bg $C.card })

$btnScan.Add_Click({
  $btnScan.Enabled=$false; $btnExport.Enabled=$false; $btnScan.Text='扫描中…'
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  $statusLeft.Text = '正在读取字体文件…'
  $barProg.Visible = $true; $barProg.Value = 0
  try {
    $script:Rows = Get-RowsWithOverride -OnProgress {
      param($i,$t,$f)
      $statusLeft.Text = "正在读取 $i / $t ：$f"
      $barProg.Maximum = [Math]::Max(1,$t); $barProg.Value = [Math]::Min($i,$barProg.Maximum)
      [System.Windows.Forms.Application]::DoEvents()
    }
    Update-Grid; $btnExport.Enabled = $true
  } catch {
    [System.Windows.Forms.MessageBox]::Show("扫描出错：$($_.Exception.Message)",'错误')
  } finally {
    $btnScan.Enabled=$true; $btnScan.Text='重新扫描'
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $barProg.Visible = $false
  }
})

$btnExport.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = '选择报告保存位置'; $dlg.SelectedPath = $scriptDir
  if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  $csv = Join-Path $dlg.SelectedPath "字体清单-$stamp.csv"
  $html = Join-Path $dlg.SelectedPath "字体版权自查报告-$stamp.html"
  try {
    $script:Rows | Select-Object 序号,字体名,判定,文件名,厂商版权,版权声明,说明,建议替代,路径 |
      Export-Csv -Path $csv -NoTypeInformation -Encoding $csvEnc
    New-ReportHtml $script:Rows $html
    $statusLeft.Text = "报告已生成：$html"
    [System.Windows.Forms.MessageBox]::Show("报告已生成：`n$html`n$csv",'完成')
  } catch {
    [System.Windows.Forms.MessageBox]::Show("导出失败：$($_.Exception.Message)",'错误')
  }
})

function Show-Detail($r) {
  $d = New-Object System.Windows.Forms.Form
  $d.Text = "字体详情 · $($r.字体名)"; $d.Size = New-Object System.Drawing.Size(640,700)
  $d.StartPosition = 'CenterParent'; $d.MinimumSize = New-Object System.Drawing.Size(480,400)
  $d.BackColor = $C.card; $d.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)

  # 顶部风险条（Dock Top）
  $head = New-Object System.Windows.Forms.Panel
  $head.Dock = 'Top'; $head.Height = 74; $head.BackColor = $RiskStyle[$r.判定].bg
  $d.Controls.Add($head)
  $tag = New-Object System.Windows.Forms.Label
  $tag.Text = $r.判定; $tag.Location = New-Object System.Drawing.Point(24,18)
  $tag.AutoSize = $true; $tag.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',14,[System.Drawing.FontStyle]::Bold)
  $tag.ForeColor = $RiskStyle[$r.判定].fg
  $head.Controls.Add($tag)
  $nm = New-Object System.Windows.Forms.Label
  $nm.Text = "$($r.字体名)　$($r.文件名)"
  $nm.Location = New-Object System.Drawing.Point(110,24); $nm.AutoSize = $true
  $nm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',11,[System.Drawing.FontStyle]::Bold)
  $nm.ForeColor = $C.text
  $head.Controls.Add($nm)

  # 底部按钮栏（Dock Bottom，独立容器，不会被正文遮挡）
  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 56; $foot.BackColor = $C.card
  $foot.Add_Paint({ param($sx,$ex)
    $pn = New-Object System.Drawing.Pen($C.line)
    $ex.Graphics.DrawLine($pn,0,0,$sx.Width,0); $pn.Dispose()
  })
  $d.Controls.Add($foot)
  $fy = 13

  # 正文容器（Dock Fill，Padding 放容器上，避免 TextBox Padding 导致文字水平错位）
  $body = New-Object System.Windows.Forms.Panel
  $body.Dock = 'Fill'; $body.BackColor = $C.card
  $body.Padding = New-Object System.Windows.Forms.Padding(0,0,0,0)
  $body.AutoScroll = $true
  $d.Controls.Add($body)

  # 正文用 Label 逐行显示（避免 TextBox 的滚动/光标怪问题）
  $ruleTxt = [string]$r.命中规则; if (-not $ruleTxt) { $ruleTxt = '—' }
  $srcTxt  = [string]$r.判定依据; if (-not $srcTxt)  { $srcTxt  = '—' }
  $evTxt   = [string]$r.命中片段; if (-not $evTxt)   { $evTxt   = '—' }
  $fields = @(
    @{ L='字体名'; V=[string]$r.字体名; Bold=$true },
    @{ L='文件名'; V=[string]$r.文件名; Bold=$false },
    @{ L='路径';   V=[string]$r.路径;   Bold=$false },
    @{ L='厂商';   V=[string]$r.厂商版权; Bold=$false },
    @{ L='版权声明'; V=[string]$r.版权声明; Bold=$false },
    @{ L='判定';   V=[string]$r.判定;   Bold=$true },
    @{ L='说明';   V=[string]$r.说明;   Bold=$false },
    @{ L='命中规则'; V=$ruleTxt; Bold=$false },
    @{ L='命中片段'; V=$evTxt;  Bold=$false },
    @{ L='判定依据'; V=$srcTxt;  Bold=$false },
    @{ L='建议替代'; V=[string]$r.建议替代; Bold=$false },
    @{ L='提示';   V='判定基于字体文件内嵌版权字段与规则库，仅供初筛，不构成法律意见。'; Bold=$false }
  )
  $fullText = @()
  $yy = 18
  $measureG = $body.CreateGraphics()
  foreach ($fld in $fields) {
    $vlen = [string]$fld.V
    $fnt = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
    if ($fld.Bold) { $fnt = New-Object System.Drawing.Font('Microsoft YaHei UI',9,[System.Drawing.FontStyle]::Bold) }
    $lh = New-Object System.Windows.Forms.Label
    $lh.Text = $fld.L + '：'
    $lh.Location = New-Object System.Drawing.Point(24,$yy)
    $lh.AutoSize = $true
    $lh.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9,[System.Drawing.FontStyle]::Bold)
    $lh.ForeColor = $C.sub
    $body.Controls.Add($lh)

    # 用实际文本测量换行高度（旧版按字符数猜，长版权声明会压到下一行）
    $sz = $measureG.MeasureString($vlen, $fnt, 490)
    $lineH = [int][Math]::Ceiling($sz.Height) + 3

    $lv2 = New-Object System.Windows.Forms.Label
    $lv2.Text = $vlen
    $lv2.Location = New-Object System.Drawing.Point(100,$yy)
    $lv2.Size = New-Object System.Drawing.Size(495,$lineH)
    $lv2.Font = $fnt
    $lv2.ForeColor = $C.text
    $body.Controls.Add($lv2)
    $fullText += "$($fld.L)：$($fld.V)"

    $yy += $lineH + 12
  }
  $measureG.Dispose()
  $body.AutoScrollMinSize = New-Object System.Drawing.Size(0,($yy + 16))

  # 复制详情（右下）
  $copy = New-Object System.Windows.Forms.Button
  $copy.Text = '复制详情'; $copy.Size = New-Object System.Drawing.Size(96,32)
  $copyX = $d.ClientSize.Width - 120
  $copy.Location = New-Object System.Drawing.Point($copyX,$fy)
  $copy.Anchor = 'Top,Right'; $copy.FlatStyle = 'Flat'
  $copy.BackColor = $C.soft; $copy.ForeColor = $C.primary
  $copy.FlatAppearance.BorderSize = 0; $copy.Cursor = [System.Windows.Forms.Cursors]::Hand
  $copy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText(($fullText -join "`r`n")); $copy.Text='已复制' })
  $foot.Controls.Add($copy)

  # 自定义判定下拉
  $lvLabel = New-Object System.Windows.Forms.Label
  $lvLabel.Text = '设为:'; $lvLabel.AutoSize = $true
  $lvLabel.Location = New-Object System.Drawing.Point(20,20)
  $foot.Controls.Add($lvLabel)
  $combo = New-Object System.Windows.Forms.ComboBox
  $combo.DropDownStyle='DropDownList'; $combo.Size=New-Object System.Drawing.Size(110,28)
  $combo.Location = New-Object System.Drawing.Point(58,14)
  foreach($opt in @('自动判定','高风险','中风险','待核实','常规','可商用')){[void]$combo.Items.Add($opt)}
  $cur = if($r.PSObject.Properties['自定义'] -and $r.自定义){[string]$r.判定}else{'自动判定'}
  $combo.SelectedItem = $cur; $foot.Controls.Add($combo)
  $btnApply = New-Object System.Windows.Forms.Button
  $btnApply.Text='应用判定'; $btnApply.Size=New-Object System.Drawing.Size(90,30)
  $btnApply.Location=New-Object System.Drawing.Point(176,$fy)
  $btnApply.FlatStyle='Flat'; $btnApply.BackColor=$C.soft; $btnApply.ForeColor=$C.primary
  $btnApply.Cursor=[System.Windows.Forms.Cursors]::Hand
  $btnApply.Add_Click({
    $lev=[string]$combo.SelectedItem
    $k=Get-WlKey $r
    if($lev -eq '自动判定'){
      if($script:WhiteList.ContainsKey($k)){$script:WhiteList.Remove($k)}
      $r.判定=$r.原判定; $r.说明=$r.原说明
    } else {
      $script:WhiteList[$k]=[pscustomobject]@{key=$k;level=$lev;note="手动设为$lev";time=(Get-Date -Format 'yyyy-MM-dd HH:mm')}
      $r.判定=$lev; $r.说明="【自定义】手动设为$lev"
    }
    Save-WhiteList; $script:NeedRefresh=$true
    $btnApply.Text='已应用'
  })
  $foot.Controls.Add($btnApply)

  # 删除到回收站（仅高风险显示，受保护）
  if($r.判定 -eq '高风险'){
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text='删除字体文件'; $btnDel.Size=New-Object System.Drawing.Size(120,30)
    $btnDel.Location=New-Object System.Drawing.Point(274,$fy)
    $btnDel.FlatStyle='Flat'; $btnDel.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#FEF2F2')
    $btnDel.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#B91C1C')
    $btnDel.Cursor=[System.Windows.Forms.Cursors]::Hand
    $btnDel.Add_Click({
      if(Delete-And-Refresh $r){ [void]$d.Close() }
    })
    $foot.Controls.Add($btnDel)
  }
  [void]$d.ShowDialog()
}

$grid.Add_CellDoubleClick({
  param($s,$e)
  if ($e.RowIndex -lt 0) { return }
  $r = $grid.Rows[$e.RowIndex].Tag
  if ($r) { Show-Detail $r }
  if ($script:NeedRescan) {
    $script:NeedRescan=$false; $script:NeedRefresh=$false
    $btnScan.Enabled=$false; $btnExport.Enabled=$false; $btnScan.Text='扫描中…'
    $statusLeft.Text='字体已删除，正在刷新列表…'; [System.Windows.Forms.Application]::DoEvents()
    try { $script:Rows=Get-RowsWithOverride; $btnExport.Enabled=$true; $statusLeft.Text="已刷新，共 $($script:Rows.Count) 个字体" }
    finally { $btnScan.Enabled=$true; $btnScan.Text='重新扫描' }
    Update-Grid
  } elseif ($script:NeedRefresh) {
    $script:NeedRefresh=$false; Update-Grid; Update-Stats
    $statusLeft.Text='自定义判定已保存'
  }
})

# 点击"操作"列的删除按钮（仅高风险行）
$grid.Add_CellClick({
  param($s,$e)
  if ($e.RowIndex -lt 0 -or $grid.Columns[$e.ColumnIndex].Name -ne '操作') { return }
  if ([string]$grid.Rows[$e.RowIndex].Cells['判定'].Value -ne '高风险') { return }
  $r = $grid.Rows[$e.RowIndex].Tag
  if ($r) { [void](Delete-And-Refresh $r) }
})

if ($SelfTest) {
  $rows = Get-RowsWithOverride
  "字体文件：{0}" -f $rows.Count
  foreach ($x in '高风险', '中风险', '待核实', '常规', '可商用') {
    "  {0}: {1}" -f $x, @($rows | Where-Object { $_.判定 -eq $x }).Count
  }
  return
}

if ($Report) {
  $rows = Get-RowsWithOverride
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  $html = Join-Path $scriptDir "字体版权自查报告-$stamp.html"
  $csv  = Join-Path $scriptDir "字体清单-$stamp.csv"
  $rows | Select-Object 序号, 字体名, 判定, 文件名, 厂商版权, 版权声明, 说明, 建议替代, 路径, 命中规则, 命中片段, 判定依据 |
    Export-Csv -Path $csv -NoTypeInformation -Encoding $csvEnc
  New-ReportHtml $rows $html
  "HTML: $html"
  "CSV : $csv"
  return
}

if ($Preview -or $PreviewScan) {
  if ($PreviewScan) {
    $script:Rows = Get-RowsWithOverride; Update-Grid
    $btnExport.Enabled = $true; $btnScan.Text = '重新扫描'
  }
  $form.Show(); [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 900; [System.Windows.Forms.Application]::DoEvents()
  $bmp = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
  $form.DrawToBitmap($bmp,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
  $bmp.Save((Join-Path $scriptDir 'preview-new.png'),[System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose(); $form.Close(); return
}

[void]$form.ShowDialog()
