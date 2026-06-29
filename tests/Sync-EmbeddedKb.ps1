<#
  Sync-EmbeddedKb.ps1 - regenerate the embedded bugcheck KB inside src/Invoke-SecondOpinion.ps1 from the
  editable source of truth data/bugchecks.json.

  Why: the tool prefers data/bugchecks.json at runtime (the editable "moat") but falls back to an embedded
  copy so it can run as a single standalone file downloaded on its own. Run this whenever data/bugchecks.json
  changes; the gate's "embedded-kb" parity guardrail fails if the embed drifts from the file.

  Read-only except for rewriting the KB-EMBED block in src. ASCII output, no BOM.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here '..\src\Invoke-SecondOpinion.ps1'
$kb   = Join-Path $here '..\data\bugchecks.json'

$srcText = [System.IO.File]::ReadAllText($src)
$nl = if ($srcText -match "`r`n") { "`r`n" } else { "`n" }                 # preserve src line endings
$json = (([System.IO.File]::ReadAllText($kb)) -replace "`r`n", "`n").TrimEnd("`n")
$jsonNl = $json -replace "`n", $nl
$block = "# KB-EMBED-START$nl`$EmbeddedBugchecksJson = @'$nl$jsonNl$nl'@$nl# KB-EMBED-END"

$pattern = "(?s)# KB-EMBED-START.*?# KB-EMBED-END"
if ($srcText -notmatch $pattern) { Write-Error 'KB-EMBED-START / KB-EMBED-END markers not found in src.'; exit 1 }
$new = [regex]::Replace($srcText, $pattern, { $block })   # constant replacement; the Match arg is unused by design
[System.IO.File]::WriteAllText($src, $new)

$count = @(($json | ConvertFrom-Json).PSObject.Properties | Where-Object { $_.Name -ne '_comment' }).Count
Write-Host "Embedded KB synced from data/bugchecks.json ($count stop codes)."
