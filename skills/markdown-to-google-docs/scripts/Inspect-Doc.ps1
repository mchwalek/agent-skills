param([Parameter(Mandatory)][string]$DocId)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\GwsClient.ps1"
function G([string[]]$argv){ return (Invoke-GwsRaw $argv) }

$d = G @('docs','documents','get','--params',('{"documentId":"'+$DocId+'"}'))
$tables=0;$imgTotal=@($d.inlineObjects.PSObject.Properties).Count
$heads=@()
foreach($el in $d.body.content){
  if($el.table){$tables++}
  if($el.paragraph){
    $ns=$el.paragraph.paragraphStyle.namedStyleType
    if($ns -match 'HEADING|TITLE'){ $t=(($el.paragraph.elements|ForEach-Object{$_.textRun.content})-join '').Trim(); if($t){$heads+=($ns+' | '+$t)} }
  }
}
Write-Output ("Tables: $tables   Images: $imgTotal   Headings/Title: "+$heads.Count)
$heads | ForEach-Object { Write-Output ("  "+$_) }

# per-table summary
$ti=0
foreach($el in $d.body.content){
  if($el.table){
    $ti++
    $rows=$el.table.tableRows.Count; $cols=$el.table.tableRows[0].tableCells.Count
    $sh=0;$bold=0;$cour=0
    foreach($row in $el.table.tableRows){foreach($cell in $row.tableCells){
      if($cell.tableCellStyle.backgroundColor.color.rgbColor){$sh++}
      foreach($ce in $cell.content){if($ce.paragraph){foreach($e in $ce.paragraph.elements){if($e.textRun.textStyle.bold){$bold++};if($e.textRun.textStyle.weightedFontFamily.fontFamily -eq 'Courier New'){$cour++}}}}
    }}
    $r0=@(); foreach($cell in $el.table.tableRows[0].tableCells){ $r0+=(($cell.content|Where-Object{$_.paragraph}|ForEach-Object{($_.paragraph.elements|ForEach-Object{$_.textRun.content})-join''})-join'').Trim() }
    Write-Output ("  Table ${ti}: ${rows}x${cols}  shaded=$sh bold=$bold courier=$cour  header=[" + ($r0 -join ' | ') + "]")
  }
}
