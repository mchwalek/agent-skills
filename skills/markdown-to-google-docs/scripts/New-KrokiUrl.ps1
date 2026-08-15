<#
New-KrokiUrl.ps1
Turns diagram sources (Graphviz .dot by default) into Kroki GET URLs, fetch-tests
each one, and rejects diagrams too wide to stay legible in the document.

Kroki encoding: base64url(zlib(source)) - 0x78 0x9C header, raw DEFLATE,
big-endian Adler-32 checksum.

Why the aspect gate: Build-GoogleDoc.ps1 contain-fits images into the 468x648 PT
printable area (shrink only, never upscale), so a very wide diagram is scaled down
by width and renders its 11 pt labels far smaller - a 2669x306 (8.7:1) diagram lands
at about 2.6 pt. Fix a failure with rankdir=TB plus constraint=false on
cross-cluster edges.

  .\New-KrokiUrl.ps1 .\diagrams\*.dot -OutJson .\diagrams\urls.json
  .\New-KrokiUrl.ps1 .\diagrams\1-endtoend.dot -NoTest
#>
param(
  [Parameter(Mandatory=$true, Position=0)][string[]]$Path,
  [string]$Type = 'graphviz',
  [string]$Format = 'png',
  [string]$OutJson,          # write a { "<file base name>": "<url>" } map for -Urls
  [double]$MaxAspect = 2.5,
  [switch]$NoTest            # skip the network fetch and the aspect check
)
$ErrorActionPreference = 'Stop'

function Get-KrokiUrl([string]$diagType,[string]$fmt,[string]$src){
  $bytes=[System.Text.Encoding]::UTF8.GetBytes($src)
  $ms=New-Object System.IO.MemoryStream
  $ds=New-Object System.IO.Compression.DeflateStream($ms,[System.IO.Compression.CompressionLevel]::Optimal,$true)
  $ds.Write($bytes,0,$bytes.Length); $ds.Dispose(); $raw=$ms.ToArray(); $ms.Dispose()
  [uint32]$a=1; [uint32]$b=0
  foreach($x in $bytes){ $a=($a+$x)%65521; $b=($b+$a)%65521 }
  $adler=[uint32](($b -shl 16) -bor $a); $ab=[BitConverter]::GetBytes($adler); [Array]::Reverse($ab)
  $zlib=[byte[]]@(0x78,0x9C)+$raw+$ab
  return "https://kroki.io/$diagType/$fmt/"+([Convert]::ToBase64String($zlib).Replace('+','-').Replace('/','_'))
}

# PNG header: big-endian width at byte 16, height at byte 20.
function Get-PngSize([byte[]]$b){
  $w=($b[16]*16777216)+($b[17]*65536)+($b[18]*256)+$b[19]
  $h=($b[20]*16777216)+($b[21]*65536)+($b[22]*256)+$b[23]
  return @{ width=$w; height=$h; aspect=[math]::Round($w/$h,2) }
}

$files = @()
foreach($p in $Path){ $files += @(Resolve-Path -Path $p | ForEach-Object { $_.Path }) }
if ($files.Count -eq 0){ throw "no files matched: $($Path -join ', ')" }

$map = [ordered]@{}
$fails = 0
foreach($f in $files){
  $key = [System.IO.Path]::GetFileNameWithoutExtension($f)
  $src = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
  $url = Get-KrokiUrl $Type $Format $src
  $map[$key] = $url
  if ($NoTest){ Write-Host "URL  $key"; continue }
  $r = $null
  try { $r = Invoke-WebRequest -Uri $url -TimeoutSec 40 -UseBasicParsing }
  catch { Write-Host "FAIL $key : $($_.Exception.Message) (400/404 usually means invalid $Type source)"; $fails++; continue }
  $ct = [string]$r.Headers['Content-Type']
  if ($r.StatusCode -ne 200 -or $ct -notmatch '^image/'){ Write-Host "FAIL $key : HTTP $($r.StatusCode) $ct"; $fails++; continue }
  if ($Format -ne 'png'){ Write-Host "OK   $key ($ct)"; continue }
  $sz = Get-PngSize $r.Content
  if ($sz.aspect -gt $MaxAspect){
    Write-Host "FAIL $key : $($sz.width)x$($sz.height) aspect $($sz.aspect) > $MaxAspect - labels will be unreadable once width-fitted to 468 PT"
    $fails++; continue
  }
  Write-Host "OK   $key  $($sz.width)x$($sz.height) aspect $($sz.aspect)"
}

if ($OutJson){
  # .NET resolves a relative path against its own CWD, not PowerShell's - make it absolute first.
  if (-not [System.IO.Path]::IsPathRooted($OutJson)){ $OutJson = Join-Path (Get-Location).Path $OutJson }
  [System.IO.File]::WriteAllText($OutJson, (ConvertTo-Json $map), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "wrote $OutJson ($($map.Count) urls)"
}
if ($fails -gt 0){ Write-Host "RESULT: FAIL ($fails diagram(s))"; exit 1 }
Write-Host "RESULT: PASS"
