<#
GwsClient.ps1 - shared transport for the @googleworkspace/cli ("gws") Docs API.
Dot-source it:  . "$PSScriptRoot\GwsClient.ps1"

Provides:
  Esc-Arg        Windows CommandLineToArgvW escaping for a single argument
  Invoke-GwsRaw  runs "node run.js <argv...>", returns the parsed JSON object

Why not just call gws?
  gws is a node shim. Routing --json through cmd.exe eats | & < > ^ (common in
  ASCII art and -> arrows), and PowerShell 5.1 native-arg quoting mangles
  embedded double quotes. So node.exe is started directly via ProcessStartInfo
  with a hand-escaped command line. .NET Framework 4.x has no ArgumentList.

Path resolution (first hit wins):
  1. $env:GWS_NODE_EXE + $env:GWS_RUN_JS   (explicit override; both required)
  2. the gws shim on PATH -> its directory holds node + node_modules\...\run.js
  3. npm root -g -> <root>\@googleworkspace\cli\run.js
#>

$script:GwsNodeExe = $null
$script:GwsRunJs   = $null

# Quote/escape one argument the way CommandLineToArgvW parses it: wrap in quotes,
# escape " as \", and double any backslashes that immediately precede a quote.
function Esc-Arg([string]$a){
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  $s = '"'; $bs = 0
  foreach($ch in $a.ToCharArray()){
    if ($ch -eq '\'){ $bs++; continue }
    if ($ch -eq '"'){ $s += ('\'*($bs*2+1)) + '"'; $bs=0; continue }
    if ($bs){ $s += ('\'*$bs); $bs=0 }
    $s += $ch
  }
  if ($bs){ $s += ('\'*($bs*2)) }
  return $s + '"'
}

function Get-GwsNodeExe([string]$preferredDir){
  if ($preferredDir){
    foreach($n in @('node.exe','node')){
      $p = Join-Path $preferredDir $n
      if (Test-Path -LiteralPath $p -PathType Leaf){ return $p }
    }
  }
  foreach($n in @('node.exe','node')){
    $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c){ return $c.Source }
  }
  return $null
}

function Resolve-GwsPaths {
  if ($script:GwsNodeExe -and $script:GwsRunJs){ return }

  # 1. explicit override
  if ($env:GWS_NODE_EXE -or $env:GWS_RUN_JS){
    if (-not ($env:GWS_NODE_EXE -and $env:GWS_RUN_JS)){
      throw "Set BOTH GWS_NODE_EXE and GWS_RUN_JS, or neither."
    }
    if (-not (Test-Path -LiteralPath $env:GWS_NODE_EXE)){ throw "GWS_NODE_EXE not found: $($env:GWS_NODE_EXE)" }
    if (-not (Test-Path -LiteralPath $env:GWS_RUN_JS)){   throw "GWS_RUN_JS not found: $($env:GWS_RUN_JS)" }
    $script:GwsNodeExe = $env:GWS_NODE_EXE
    $script:GwsRunJs   = $env:GWS_RUN_JS
    return
  }

  $tried = @()

  # 2. the gws shim on PATH
  foreach($n in @('gws.cmd','gws.ps1','gws')){
    $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c -or -not $c.Source){ continue }
    $dir = Split-Path -Parent $c.Source
    $run = Join-Path $dir 'node_modules\@googleworkspace\cli\run.js'
    $tried += $run
    if (Test-Path -LiteralPath $run -PathType Leaf){
      $node = Get-GwsNodeExe $dir
      if ($node){ $script:GwsNodeExe = $node; $script:GwsRunJs = $run; return }
    }
  }

  # 3. npm global root
  $npmRoot = $null
  try { $npmRoot = (& npm root -g 2>$null | Select-Object -First 1) } catch { $npmRoot = $null }
  if ($npmRoot){
    $run = Join-Path $npmRoot.Trim() '@googleworkspace\cli\run.js'
    $tried += $run
    if (Test-Path -LiteralPath $run -PathType Leaf){
      $node = Get-GwsNodeExe (Split-Path -Parent $npmRoot.Trim())
      if ($node){ $script:GwsNodeExe = $node; $script:GwsRunJs = $run; return }
    }
  }

  $msg = "gws CLI not found. Install it with 'npm install -g @googleworkspace/cli' and authenticate " +
         "('gws auth login'), or set GWS_NODE_EXE and GWS_RUN_JS explicitly."
  if ($tried.Count){ $msg += "`nLooked for run.js at:`n  " + (($tried | Select-Object -Unique) -join "`n  ") }
  else { $msg += "`nNo 'gws' shim was found on PATH and 'npm root -g' returned nothing." }
  throw $msg
}

# Runs the gws CLI with the given argv and returns the response parsed from JSON.
# Throws on empty or non-JSON output (a swallowed error otherwise looks like success).
function Invoke-GwsRaw([string[]]$argv){
  Resolve-GwsPaths
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:GwsNodeExe
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  # REQUIRED: without this, Unicode read back from the API arrives as mojibake.
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $line = Esc-Arg $script:GwsRunJs
  foreach($a in $argv){ $line += ' ' + (Esc-Arg $a) }
  $psi.Arguments = $line
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if (-not $out){ throw ("gws returned no output for: " + ($argv -join ' ') + "`nSTDERR: " + $err) }
  try { return ($out | ConvertFrom-Json) }
  catch { throw ("gws returned non-JSON for [" + ($argv -join ' ') + "]:`n" + $out) }
}
