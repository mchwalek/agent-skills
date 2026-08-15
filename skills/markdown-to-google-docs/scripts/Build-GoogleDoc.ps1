<#
Build-GoogleDoc.ps1
Converts google-doc-content.md into a natively-formatted Google Doc:
 - # / ## / ### / #### -> TITLE / HEADING_1 / HEADING_2 / HEADING_3
 - markdown tables -> real Google Docs tables (header row bold + shaded)
 - **bold**, `code` (Courier New) inline styling
 - bullet lists
 - fenced ``` blocks -> monospace ASCII art (preserved)
 - [[DIAGRAM:key]] placeholder -> inline image rendered via Kroki

Approach: build the body top-to-bottom. Non-table content is inserted as a text
buffer, then paragraph+text styling is applied in one batch using recorded ranges.
Tables and images are flushed inline (each needs a live document read for indices).

Requires: gws (Docs API, authenticated), network. Diagrams need a urls.json map
produced by New-KrokiUrl.ps1; without -Urls, [[DIAGRAM:key]] blocks are skipped.

  .\Build-GoogleDoc.ps1 -Md .\content.md
  .\Build-GoogleDoc.ps1 -Md .\content.md -Urls .\diagrams\urls.json -OutIdFile .\gdoc-id.txt
#>
param(
  [Parameter(Mandatory=$true)][string]$Md,   # markdown source
  [string]$Urls,                             # optional { "key": "https://kroki.io/..." } map
  [string]$Title,                            # defaults to the first '# ' heading in $Md
  [string]$OutIdFile,                        # optional: write the new documentId here
  [string]$DocId                             # optional: rebuild in place into this existing doc
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\GwsClient.ps1"

$Md = (Resolve-Path -LiteralPath $Md).Path
$diagUrls = $null
if ($Urls){
  if (-not (Test-Path -LiteralPath $Urls)){ throw "urls file not found: $Urls" }
  $diagUrls = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Urls).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

# ---------- gws helpers ----------
# Transport (node discovery, Windows arg escaping, UTF-8 stdout) lives in GwsClient.ps1.
function Invoke-Gws([string[]]$GwsArgs, [string]$JsonBody, [string]$ParamsJson){
  $argv = @('docs') + $GwsArgs
  if ($ParamsJson) { $argv += @('--params', $ParamsJson) }
  if ($JsonBody)   { $argv += @('--json',   $JsonBody) }
  return (Invoke-GwsRaw $argv)
}
function New-Doc([string]$t){
  $body = @{ title = $t } | ConvertTo-Json -Compress
  (Invoke-Gws @('documents','create') $body $null).documentId
}
$script:MaxBody = 28000   # keep total process command line under Windows' 32767 limit
$script:WriteCount = 0

function Batch-Raw([string]$docId, $arr){
  if ($arr.Count -eq 0){ return $null }
  $body = @{ requests = $arr } | ConvertTo-Json -Compress -Depth 40
  $attempt = 0
  while ($true){
    $r = Invoke-Gws @('documents','batchUpdate') $body ("{`"documentId`":`"$docId`"}")
    $script:WriteCount++
    if (-not $r.error){ Start-Sleep -Milliseconds 1100; return $r }
    $msg = $r.error.message
    if ($msg -match 'Quota exceeded' -and $attempt -lt 6){
      $attempt++; $wait = 20 * $attempt
      Write-Host ("  [quota] backing off ${wait}s (attempt $attempt)...")
      Start-Sleep -Seconds $wait
      continue
    }
    throw ("batchUpdate error: " + $msg + "`nBODY: " + $body.Substring(0,[Math]::Min(400,$body.Length)))
  }
}

# Chunks a request list so each sub-batch's JSON body stays under MaxBody.
# NOTE: only safe for requests that do NOT shift indices relative to each other
# (styling requests). Index-shifting inserts must be handled by the caller.
function Batch([string]$docId, $requests){
  $arr = @($requests)
  if ($arr.Count -eq 0){ return $null }
  $chunk = @(); $len = 20
  foreach($req in $arr){
    $jl = (($req | ConvertTo-Json -Compress -Depth 40).Length) + 1
    if ($chunk.Count -gt 0 -and ($len + $jl) -gt $script:MaxBody){
      Batch-Raw $docId $chunk | Out-Null
      $chunk = @(); $len = 20
    }
    $chunk += $req; $len += $jl
  }
  if ($chunk.Count -gt 0){ Batch-Raw $docId $chunk | Out-Null }
  return $null
}

# Inserts a large text string at $index by splitting into <MaxBody chunks,
# advancing the index. Returns nothing; caller re-reads indices afterwards.
function Insert-BigText([string]$docId, [int]$index, [string]$text){
  $max = $script:MaxBody - 200
  $pos = 0; $cur = $index
  while ($pos -lt $text.Length){
    $take = [Math]::Min($max, $text.Length - $pos)
    # avoid splitting inside a surrogate pair
    $slice = $text.Substring($pos, $take)
    Batch-Raw $docId @( @{ insertText = @{ location=@{ index=$cur }; text=$slice } } ) | Out-Null
    $cur += $slice.Length
    $pos += $take
  }
}
function Get-EndIndex([string]$docId){
  $doc = Invoke-Gws @('documents','get') $null ("{`"documentId`":`"$docId`"}")
  $content = $doc.body.content
  # body endIndex is last element's endIndex; insertion point is endIndex-1
  ($content[$content.Count-1].endIndex) - 1
}

# ---------- inline markdown: return plain text + style ranges (relative offsets) ----------
function Parse-Inline([string]$s){
  $plain = New-Object System.Text.StringBuilder
  $ranges = @()   # @{start;end;type}  type: bold | italic | code
  $i = 0
  while ($i -lt $s.Length){
    $c = $s[$i]
    if ($c -eq '`'){
      $j = $s.IndexOf('`', $i+1)
      if ($j -lt 0){ [void]$plain.Append($c); $i++; continue }
      $txt = $s.Substring($i+1, $j-$i-1)
      $st = $plain.Length; [void]$plain.Append($txt)
      $ranges += @{ start=$st; end=$plain.Length; type='code' }
      $i = $j+1; continue
    }
    if ($c -eq '*' -and $i+1 -lt $s.Length -and $s[$i+1] -eq '*'){
      $j = $s.IndexOf('**', $i+2)
      if ($j -lt 0){ [void]$plain.Append($c); $i++; continue }
      $txt = $s.Substring($i+2, $j-$i-2)
      $st = $plain.Length; [void]$plain.Append($txt)
      $ranges += @{ start=$st; end=$plain.Length; type='bold' }
      $i = $j+2; continue
    }
    # single '*' italic (checked AFTER '**' so bold is never split into two italics)
    if ($c -eq '*'){
      $j = $s.IndexOf('*', $i+1)
      if ($j -lt 0){ [void]$plain.Append($c); $i++; continue }
      $txt = $s.Substring($i+1, $j-$i-1)
      $st = $plain.Length; [void]$plain.Append($txt)
      $ranges += @{ start=$st; end=$plain.Length; type='italic' }
      $i = $j+1; continue
    }
    [void]$plain.Append($c); $i++
  }
  return @{ text = $plain.ToString(); ranges = $ranges }
}

# Split a markdown table row into cells: split on '|' only OUTSIDE backtick spans,
# treat '\|' as a literal pipe, then drop the leading/trailing empty cells and trim.
function Split-Row([string]$line){
  $s = $line.Trim()
  $cells = New-Object System.Collections.ArrayList
  $cur = New-Object System.Text.StringBuilder
  $inCode = $false
  $i = 0
  while ($i -lt $s.Length){
    $ch = $s[$i]
    if ($ch -eq '\' -and $i+1 -lt $s.Length -and $s[$i+1] -eq '|'){ [void]$cur.Append('|'); $i += 2; continue }
    if ($ch -eq '`'){ $inCode = -not $inCode; [void]$cur.Append($ch); $i++; continue }
    if ($ch -eq '|' -and -not $inCode){ [void]$cells.Add($cur.ToString().Trim()); $cur = New-Object System.Text.StringBuilder; $i++; continue }
    [void]$cur.Append($ch); $i++
  }
  [void]$cells.Add($cur.ToString().Trim())
  # a row like "| a | b |" yields leading & trailing empty cells -> drop them
  if ($cells.Count -gt 0 -and $cells[0] -eq ''){ $cells.RemoveAt(0) }
  if ($cells.Count -gt 0 -and $cells[$cells.Count-1] -eq ''){ $cells.RemoveAt($cells.Count-1) }
  return ,($cells.ToArray())
}

# ---------- parse markdown into a block list ----------
# block types: title, h1, h2, h3, para, bullet, code (ascii), table, diagram
function Parse-Blocks([string[]]$lines){
  $blocks = @()
  $i = 0
  while ($i -lt $lines.Count){
    $line = $lines[$i]
    if ($line -match '^\s*$'){ $i++; continue }

    if ($line -match '^\[\[DIAGRAM:(?<k>[^\]]+)\]\]\s*$'){ $blocks += @{ t='diagram'; key=$Matches.k }; $i++; continue }

    if ($line -match '^# (.*)'){ $blocks += @{ t='title'; text=$Matches[1] }; $i++; continue }
    if ($line -match '^## (.*)'){ $blocks += @{ t='h1'; text=$Matches[1] }; $i++; continue }
    if ($line -match '^### (.*)'){ $blocks += @{ t='h2'; text=$Matches[1] }; $i++; continue }
    if ($line -match '^#### (.*)'){ $blocks += @{ t='h3'; text=$Matches[1] }; $i++; continue }

    if ($line -match '^```'){
      $buf = @(); $i++
      while ($i -lt $lines.Count -and $lines[$i] -notmatch '^```'){ $buf += $lines[$i]; $i++ }
      $i++  # closing fence
      $blocks += @{ t='code'; text=($buf -join "`n") }
      continue
    }

    # table: a line starting with | followed by a |---| separator
    if ($line -match '^\s*\|' -and $i+1 -lt $lines.Count -and $lines[$i+1] -match '^\s*\|?[\s:\-\|]+\|?\s*$'){
      $rows = @()
      $rows += ,(Split-Row $line)
      $i += 2  # skip header + separator
      while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|'){
        $rows += ,(Split-Row $lines[$i])
        $i++
      }
      $blocks += @{ t='table'; rows=$rows }
      continue
    }

    if ($line -match '^\s*[-*] (.*)'){
      # a hard-wrapped bullet continues on following non-blank, non-structural lines
      $btext = $Matches[1].Trim(); $i++
      while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*$' -and $lines[$i] -notmatch '^(#|```|\s*\||\s*[-*] |\[\[DIAGRAM)'){
        $btext += ' ' + $lines[$i].Trim(); $i++
      }
      $blocks += @{ t='bullet'; text=$btext }; continue
    }

    # paragraph: accumulate until blank / structural line
    $buf = @($line); $i++
    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*$' -and $lines[$i] -notmatch '^(#|```|\s*\||\s*[-*] |\[\[DIAGRAM)'){
      $buf += $lines[$i]; $i++
    }
    $blocks += @{ t='para'; text=(($buf | ForEach-Object { $_.Trim() }) -join ' ') }
  }
  return $blocks
}

# =====================================================================
# Read first: the title defaults to the document's own H1.
# Get-Content -Raw in PS 5.1 decodes UTF-8-without-BOM as ANSI and mangles arrows/em-dashes.
$raw = [System.IO.File]::ReadAllText($Md, [System.Text.Encoding]::UTF8)
$lines = $raw -split "`r?`n"
if (-not $Title){
  foreach($l in $lines){ if ($l -match '^#\s+(.+)$'){ $Title = $Matches[1].Trim(); break } }
  if (-not $Title){ $Title = [System.IO.Path]::GetFileNameWithoutExtension($Md) }
}

Write-Host "Creating document..."
if ($DocId) {
  $docId = $DocId
  Write-Host "Reusing existing document $docId (wiping body)..."
  # Get-EndIndex already returns (body endIndex - 1), i.e. the insertion point, which is
  # exactly the highest deletable index -- the Docs API refuses to delete the body's
  # final newline. startIndex=1 skips the implicit leading position.
  $end = Get-EndIndex $docId
  if ($end -gt 1) {
    Batch-Raw $docId @( @{ deleteContentRange = @{ range = @{ startIndex = 1; endIndex = $end } } } ) | Out-Null
  }
  $after = Get-EndIndex $docId
  Write-Host "  body wiped (endIndex $end -> $after)"
} else {
  $docId = New-Doc $Title
}
Write-Host "documentId=$docId"
# drop the first H1 (it becomes the doc TITLE which gws already set); keep as-is otherwise
$blocks = Parse-Blocks $lines

# We process blocks sequentially. Text-y blocks are batched into a text buffer with
# recorded (startOffset,endOffset,style) then flushed. Tables/images/code force a flush
# because they need live indices.

$style = @{ title='TITLE'; h1='HEADING_1'; h2='HEADING_2'; h3='HEADING_3' }

# textBuffer accumulates paragraphs; we track each paragraph's char range within the buffer
$script:sb = New-Object System.Text.StringBuilder
$script:paraMarks = @()    # @{start;end;named;bullet;inlineRanges}
function Add-Para([string]$text, [string]$named, [bool]$bullet){
  $inline = Parse-Inline $text
  $start = $script:sb.Length
  [void]$script:sb.Append($inline.text)
  [void]$script:sb.Append("`n")
  $script:paraMarks += @{ start=$start; end=$start+$inline.text.Length; named=$named; bullet=$bullet; inline=$inline.ranges }
}

function Flush-Text([string]$docId){
  if ($script:sb.Length -eq 0){ return }
  $insertAt = Get-EndIndex $docId
  $text = $script:sb.ToString()
  # 1) insert the whole text buffer (chunked to stay under the arg-length limit)
  Insert-BigText $docId $insertAt $text
  # 2) build style requests (indices offset by $insertAt)
  $reqs = @()
  foreach($m in $script:paraMarks){
    $ps = $insertAt + $m.start
    $pe = $insertAt + $m.end
    if ($m.named -and $m.named -ne 'NORMAL_TEXT'){
      $reqs += @{ updateParagraphStyle = @{ range=@{ startIndex=$ps; endIndex=$pe+1 }; paragraphStyle=@{ namedStyleType=$m.named }; fields='namedStyleType' } }
    }
    if ($m.bullet){
      $reqs += @{ createParagraphBullets = @{ range=@{ startIndex=$ps; endIndex=$pe+1 }; bulletPreset='BULLET_DISC_CIRCLE_SQUARE' } }
    }
    foreach($r in $m.inline){
      $rs = $insertAt + $m.start + $r.start
      $re = $insertAt + $m.start + $r.end
      if ($r.type -eq 'bold'){
        $reqs += @{ updateTextStyle = @{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ bold=$true }; fields='bold' } }
      } elseif ($r.type -eq 'italic'){
        $reqs += @{ updateTextStyle = @{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ italic=$true }; fields='italic' } }
      } elseif ($r.type -eq 'code'){
        $reqs += @{ updateTextStyle = @{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ weightedFontFamily=@{ fontFamily='Courier New' }; backgroundColor=@{ color=@{ rgbColor=@{ red=0.95; green=0.95; blue=0.95 } } } }; fields='weightedFontFamily,backgroundColor' } }
      }
    }
  }
  if ($reqs.Count -gt 0){ Batch $docId $reqs | Out-Null }
  # reset buffer
  $script:sb = New-Object System.Text.StringBuilder
  $script:paraMarks = @()
}

function Insert-Code([string]$docId, [string]$text){
  $insertAt = Get-EndIndex $docId
  $payload = $text + "`n"
  Insert-BigText $docId $insertAt $payload
  $reqs = @(
    @{ updateTextStyle=@{ range=@{ startIndex=$insertAt; endIndex=$insertAt+$text.Length }; textStyle=@{ weightedFontFamily=@{ fontFamily='Courier New' }; fontSize=@{ magnitude=8; unit='PT' } }; fields='weightedFontFamily,fontSize' } },
    @{ updateParagraphStyle=@{ range=@{ startIndex=$insertAt; endIndex=$insertAt+$text.Length+1 }; paragraphStyle=@{ shading=@{ backgroundColor=@{ color=@{ rgbColor=@{ red=0.97; green=0.97; blue=0.97 } } } } }; fields='shading' } }
  )
  Batch $docId $reqs | Out-Null
}

# Printable area of a default Docs page: US Letter (8.5x11in) minus 1in margins all round.
$script:MaxImgW = 468   # 6.5in
$script:MaxImgH = 648   # 9in

# Reads a PNG's intrinsic size from its IHDR header and converts px -> PT at 96 DPI.
# Returns $null on any fetch/parse failure so the caller can fall back.
# NOTE: $bytes MUST be typed [byte[]]. Invoke-WebRequest can hand back .Content as a
# String, and indexing a String yields chars -> silently wrong dimensions. The cast forces
# a byte array. Multiplication (not -shl) mirrors New-KrokiUrl.ps1's proven reader.
function Get-PngSizeFromBytes([byte[]]$bytes){
  if ($bytes.Length -lt 24 -or $bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50) { return $null }
  $w = ($bytes[16]*16777216)+($bytes[17]*65536)+($bytes[18]*256)+$bytes[19]
  $h = ($bytes[20]*16777216)+($bytes[21]*65536)+($bytes[22]*256)+$bytes[23]
  if ($w -le 0 -or $h -le 0) { return $null }
  return @{ w = $w * 0.75; h = $h * 0.75 }   # px -> PT at 96 DPI
}

function Get-PngSizePt([string]$url){
  try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 } catch { return $null }
  try { return (Get-PngSizeFromBytes ([byte[]]$r.Content)) } catch { return $null }
}

function Insert-Diagram([string]$docId, [string]$url){
  $insertAt = Get-EndIndex $docId
  # insert a newline paragraph to host the image, then the image at that index
  Batch $docId @( @{ insertText=@{ location=@{ index=$insertAt }; text="`n" } } ) | Out-Null

  # Contain-fit: shrink to fit the printable area, never upscale. The Docs API does
  # not auto-fit, so an oversized image would otherwise run past the margins.
  $img = @{ location=@{ index=$insertAt }; uri=$url }
  $sz  = Get-PngSizePt $url
  if ($sz){
    $scale = [Math]::Min(1.0, [Math]::Min($script:MaxImgW/$sz.w, $script:MaxImgH/$sz.h))
    $img.objectSize = @{
      width  = @{ magnitude=[Math]::Round($sz.w*$scale,1); unit='PT' }
      height = @{ magnitude=[Math]::Round($sz.h*$scale,1); unit='PT' }
    }
    Write-Host ("  image {0}x{1}pt scale {2}" -f [Math]::Round($sz.w,1), [Math]::Round($sz.h,1), [Math]::Round($scale,3))
  } else {
    $img.objectSize = @{ width=@{ magnitude=$script:MaxImgW; unit='PT' } }   # fallback: previous behaviour
    Write-Host "  image size unknown - falling back to $($script:MaxImgW) PT width"
  }
  Batch $docId @( @{ insertInlineImage=$img } ) | Out-Null
}

function Insert-Table([string]$docId, $rows){
  $nRows = $rows.Count
  $nCols = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
  $insertAt = Get-EndIndex $docId
  Batch $docId @( @{ insertTable=@{ location=@{ index=$insertAt }; rows=$nRows; columns=$nCols } } ) | Out-Null
  # read back to find each cell's paragraph start index
  $doc = Invoke-Gws @('documents','get') $null ("{`"documentId`":`"$docId`"}")
  $tableEl = $doc.body.content | Where-Object { $_.table -and $_.startIndex -ge $insertAt } | Select-Object -First 1
  if (-not $tableEl){ throw "inserted table not found" }
  # Build items row-major AND capture each cell's paragraph startIndex in the SAME walk,
  # so text and index can never misalign.
  $items = @()
  $r = 0
  foreach($row in $tableEl.table.tableRows){
    $c = 0
    foreach($cell in $row.tableCells){
      $p = $cell.content | Where-Object { $_.paragraph } | Select-Object -First 1
      $val = if ($c -lt $rows[$r].Count){ $rows[$r][$c] } else { '' }
      $inline = Parse-Inline $val
      $items += @{ index=[int]$p.startIndex; text=$inline.text; header=($r -eq 0); ranges=$inline.ranges }
      $c++
    }
    $r++
  }
  # sanity: indices must be unique
  $dupes = ($items.index | Group-Object | Where-Object { $_.Count -gt 1 })
  if ($dupes){ throw ("duplicate cell indices: " + (($dupes.Name) -join ',')) }
  # insert all cell text in ONE ordered batch: requests apply sequentially, so listing
  # them high-index -> low-index keeps every lower index valid as we go. Far fewer API calls.
  $cellInserts = @()
  foreach($it in ($items | Sort-Object { $_.index } -Descending)){
    if ($it.text.Length -gt 0){
      $cellInserts += @{ insertText=@{ location=@{ index=$it.index }; text=$it.text } }
    }
  }
  if ($cellInserts.Count -gt 0){ Batch-Raw $docId $cellInserts | Out-Null }
  # now re-read to compute styling ranges (indices shifted by inserted text)
  $doc2 = Invoke-Gws @('documents','get') $null ("{`"documentId`":`"$docId`"}")
  $tableEl2 = $doc2.body.content | Where-Object { $_.table -and $_.startIndex -ge $insertAt } | Select-Object -First 1
  $textReqs = @()
  $k = 0
  foreach($row in $tableEl2.table.tableRows){
    foreach($cell in $row.tableCells){
      $p = $cell.content | Where-Object { $_.paragraph } | Select-Object -First 1
      $cellStart = [int]$p.startIndex
      $it = $items[$k]
      if ($it.header -and $it.text.Length -gt 0){
        $textReqs += @{ updateTextStyle=@{ range=@{ startIndex=$cellStart; endIndex=$cellStart+$it.text.Length }; textStyle=@{ bold=$true }; fields='bold' } }
      }
      foreach($rg in $it.ranges){
        $rs = $cellStart + $rg.start; $re = $cellStart + $rg.end
        if ($rg.type -eq 'code'){
          $textReqs += @{ updateTextStyle=@{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ weightedFontFamily=@{ fontFamily='Courier New' }; fontSize=@{ magnitude=9; unit='PT' } }; fields='weightedFontFamily,fontSize' } }
        } elseif ($rg.type -eq 'bold'){
          $textReqs += @{ updateTextStyle=@{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ bold=$true }; fields='bold' } }
        } elseif ($rg.type -eq 'italic'){
          $textReqs += @{ updateTextStyle=@{ range=@{ startIndex=$rs; endIndex=$re }; textStyle=@{ italic=$true }; fields='italic' } }
        }
      }
      $k++
    }
  }
  if ($textReqs.Count -gt 0){ Batch $docId $textReqs | Out-Null }
  # shade header row (separate batch; explicit column counter, not .IndexOf)
  $shadeReqs = @()
  $ncH = $tableEl2.table.tableRows[0].tableCells.Count
  for($ci=0; $ci -lt $ncH; $ci++){
    $shadeReqs += @{ updateTableCellStyle=@{ tableRange=@{ tableCellLocation=@{ tableStartLocation=@{ index=[int]$tableEl2.startIndex }; rowIndex=0; columnIndex=$ci }; rowSpan=1; columnSpan=1 }; tableCellStyle=@{ backgroundColor=@{ color=@{ rgbColor=@{ red=0.85; green=0.9; blue=0.97 } } } }; fields='backgroundColor' } }
  }
  if ($shadeReqs.Count -gt 0){ Batch $docId $shadeReqs | Out-Null }
}

# ---------- main loop ----------
$first = $true
foreach($b in $blocks){
  switch($b.t){
    'title' { if ($first){ $first=$false; continue } ; Add-Para $b.text 'HEADING_1' $false }  # extra top-level # (shouldn't happen)
    'h1'    { Add-Para $b.text 'HEADING_1' $false }
    'h2'    { Add-Para $b.text 'HEADING_2' $false }
    'h3'    { Add-Para $b.text 'HEADING_3' $false }
    'para'  { Add-Para $b.text 'NORMAL_TEXT' $false }
    'bullet'{ Add-Para $b.text 'NORMAL_TEXT' $true }
    'code'  { Flush-Text $docId; Write-Host "  code block (writes=$($script:WriteCount))"; Insert-Code $docId $b.text }
    'diagram' { Flush-Text $docId; Write-Host "  diagram $($b.key) (writes=$($script:WriteCount))"; if ($diagUrls -and $diagUrls.($b.key)){ Insert-Diagram $docId $diagUrls.($b.key) } else { Write-Host "  (no url for diagram $($b.key))" } }
    'table' { Flush-Text $docId; Write-Host "  table $($b.rows.Count)x$($b.rows[0].Count) (writes=$($script:WriteCount))"; Insert-Table $docId $b.rows }
  }
  $first = $false
}
Flush-Text $docId

Write-Host ""
Write-Host "DONE. URL: https://docs.google.com/document/d/$docId"
if ($OutIdFile){
  Set-Content -LiteralPath $OutIdFile -Value $docId -NoNewline
  Write-Host "documentId written to $OutIdFile"
}
