<#
.SYNOPSIS
  Verifies that a built Google Doc is correctly formatted.
.DESCRIPTION
  Fetches the doc through GwsClient.ps1 (PS5.1 native arg passing and cmd.exe
  both corrupt JSON containing | & < > " and spaces) and asserts:
    1. document fetched
    2. table count
    3. every table's row 0 is a proper header (shaded, bold, no empty cell)
    4. inline image count + non-empty contentUri
    5. HEADING_1 / HEADING_2 minimum counts
    6. Unicode integrity (no mojibake; -ExpectUnicode also requires -> / x / em-dash)
  Prints PASS:/FAIL: per check, then RESULT: PASS (exit 0) or RESULT: FAIL (n) (exit 1).
#>
param(
  [Parameter(Mandatory=$true)][string]$DocId,
  [int]$MinH1 = -1,
  [int]$MinH2 = -1,
  [int]$ExpectTables = -1,
  [int]$ExpectImages = -1,
  [switch]$ExpectUnicode    # assert the doc contains -> / x / em-dash (content-specific)
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\GwsClient.ps1"

function Gws([string[]]$argv){ return (Invoke-GwsRaw $argv) }

$fails = 0
function Pass([string]$m){ Write-Host "PASS: $m" }
function Fail([string]$m){ Write-Host "FAIL: $m"; $script:fails++ }

# --- Check 1: fetch -----------------------------------------------------------
$d = $null
try { $d = Gws @('docs','documents','get','--params',('{"documentId":"'+$DocId+'"}')) } catch { $d = $null }
if(-not $d -or -not $d.body -or -not $d.body.content){
  Fail "document fetch ($DocId) - no body.content returned"
  Write-Host "RESULT: FAIL (1 checks failed)"
  exit 1
}
$content = @($d.body.content)
Pass "document fetched ($($content.Count) structural elements)"

# --- Collect ------------------------------------------------------------------
$paras  = @($content | Where-Object { $_.paragraph })
$tables = @($content | Where-Object { $_.table })

function Get-CellText($cell){
  $sb = New-Object System.Text.StringBuilder
  foreach($c in @($cell.content)){
    if($c.paragraph){ foreach($e in @($c.paragraph.elements)){ if($e.textRun){ $null=$sb.Append($e.textRun.content) } } }
  }
  return $sb.ToString()
}

# --- Check 2: table count -----------------------------------------------------
if($ExpectTables -ge 0){
  if($tables.Count -eq $ExpectTables){ Pass "table count = $ExpectTables" }
  else { Fail "table count = $($tables.Count), expected $ExpectTables" }
} else { Write-Host "SKIP: table count (not supplied)" }

# --- Check 3: header row of every table ---------------------------------------
for($t=0; $t -lt $tables.Count; $t++){
  $rows = @($tables[[int]$t].table.tableRows)
  if($rows.Count -lt 1){ Fail "table $($t+1): no rows"; continue }
  $cells = @($rows[0].tableCells)
  if($cells.Count -lt 1){ Fail "table $($t+1): header row has no cells"; continue }

  $shaded = 0; $bold = 0; $empty = 0
  foreach($cell in $cells){
    if($cell.tableCellStyle -and $cell.tableCellStyle.backgroundColor -and `
       $cell.tableCellStyle.backgroundColor.color -and $cell.tableCellStyle.backgroundColor.color.rgbColor){ $shaded++ }
    foreach($c in @($cell.content)){
      if($c.paragraph){ foreach($e in @($c.paragraph.elements)){
        if($e.textRun -and $e.textRun.textStyle -and $e.textRun.textStyle.bold){ $bold++ }
      } }
    }
    if((Get-CellText $cell).Trim() -eq ''){ $empty++ }
  }

  $probs = @()
  if($shaded -lt 1){ $probs += "no shaded cell" }
  if($bold   -lt 1){ $probs += "no bold run" }
  if($empty  -gt 0){ $probs += "$empty empty cell(s)" }
  if($probs.Count -eq 0){ Pass "table $($t+1) header row ($($cells.Count) cells): shaded=$shaded bold=$bold empty=0" }
  else { Fail "table $($t+1) header row: $($probs -join '; ')" }
}

# --- Check 4: inline images ---------------------------------------------------
$imgProps = @()
if($d.inlineObjects){ $imgProps = @($d.inlineObjects.PSObject.Properties) }
if($ExpectImages -ge 0){
  if($imgProps.Count -eq $ExpectImages){ Pass "inline image count = $ExpectImages" }
  else { Fail "inline image count = $($imgProps.Count), expected $ExpectImages" }
} else { Write-Host "SKIP: inline image count (not supplied)" }

$badUri = 0
foreach($p in $imgProps){
  $uri = $null
  $eo = $p.Value.inlineObjectProperties.embeddedObject
  if($eo -and $eo.imageProperties){ $uri = $eo.imageProperties.contentUri }
  if([string]::IsNullOrWhiteSpace($uri)){ $badUri++ }
}
if($imgProps.Count -gt 0){
  if($badUri -eq 0){ Pass "all $($imgProps.Count) inline images have a non-empty contentUri" }
  else { Fail "$badUri of $($imgProps.Count) inline images have an empty contentUri" }
}

# --- Check 5: headings --------------------------------------------------------
$h1 = 0; $h2 = 0
foreach($p in $paras){
  $ns = $p.paragraph.paragraphStyle.namedStyleType
  if($ns -eq 'HEADING_1'){ $h1++ }
  elseif($ns -eq 'HEADING_2'){ $h2++ }
}
if($MinH1 -ge 0){
  if($h1 -ge $MinH1){ Pass "HEADING_1 count = $h1 (>= $MinH1)" } else { Fail "HEADING_1 count = $h1, expected >= $MinH1" }
} else { Write-Host "SKIP: HEADING_1 minimum (not supplied)" }
if($MinH2 -ge 0){
  if($h2 -ge $MinH2){ Pass "HEADING_2 count = $h2 (>= $MinH2)" } else { Fail "HEADING_2 count = $h2, expected >= $MinH2" }
} else { Write-Host "SKIP: HEADING_2 minimum (not supplied)" }

# --- Check 6: Unicode integrity (body paragraphs + table cell text) -----------
$all = New-Object System.Text.StringBuilder
foreach($p in $paras){ foreach($e in @($p.paragraph.elements)){ if($e.textRun){ $null=$all.Append($e.textRun.content) } } }
foreach($tb in $tables){ foreach($row in @($tb.table.tableRows)){ foreach($cell in @($row.tableCells)){ $null=$all.Append((Get-CellText $cell)) } } }
$text = $all.ToString()

$hasArrow = $text.IndexOf([char]0x2192) -ge 0
$hasTimes = $text.IndexOf([char]0x00D7) -ge 0
$hasEmDash= $text.IndexOf([char]0x2014) -ge 0
if($ExpectUnicode){
  if($hasArrow -or $hasTimes -or $hasEmDash){
    Pass ("Unicode present (U+2192=$hasArrow U+00D7=$hasTimes U+2014=$hasEmDash)")
  } else {
    Fail "no U+2192 / U+00D7 / U+2014 found in $($text.Length) chars of text"
  }
} else {
  Write-Host "SKIP: Unicode presence (pass -ExpectUnicode if the source uses -> / x / em-dash)"
}

$mojibake = 0
for($i=0; $i -lt ($text.Length-1); $i++){
  $c = [int][char]$text[$i]
  if($c -eq 0x00C3 -or $c -eq 0x00E2){
    if([int][char]$text[$i+1] -gt 0x007F){ $mojibake++ }
  }
}
if($mojibake -eq 0){ Pass "no mojibake sequences" } else { Fail "$mojibake mojibake sequence(s) found" }

# --- Result -------------------------------------------------------------------
if($fails -eq 0){ Write-Host "RESULT: PASS"; exit 0 }
Write-Host "RESULT: FAIL ($fails checks failed)"
exit 1
