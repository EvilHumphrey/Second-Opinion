<#
.SYNOPSIS
  Second Opinion - a read-only second opinion for a misbehaving Windows 11 PC.

.DESCRIPTION
  One read-only pass over crash/reliability/drive/device signals, fused into a
  confidence-tiered list of likely culprits. Writes report.html (NOT redacted - local/helper
  only) and ai-prompt.txt (key identifiers removed, best-effort). Makes NO changes to the
  machine. See docs/DESIGN.md.

.NOTES
  Targets Windows PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.
  Read-only by design - every cmdlet here only reads.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [int]$Days = 30,
    [string]$OutDir,
    [switch]$OpenReport,
    [switch]$NoRedact,
    [switch]$NoIntake
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Paths + knowledge base
# ---------------------------------------------------------------------------
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot
$DataDir     = Join-Path $ProjectRoot 'data'
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'out' }

function Invoke-Safe {
    param([scriptblock]$Script, $Default = $null)
    try { & $Script } catch { $Default }
}

function Import-Kb($name) {
    $p = Join-Path $DataDir $name
    if (Test-Path $p) { Invoke-Safe { Get-Content -Raw -Path $p | ConvertFrom-Json } } else { $null }
}
# bugchecks.json is the one consumed data KB (Get-BugcheckInfo). The event vocabulary is NOT data-driven:
# the collectors below are the single source of truth for which events the scorer acts on.
$BugchecksKb = Import-Kb 'bugchecks.json'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Format-Bugcheck($code) {
    $c = [int64]$code
    if ($c -le 0xFF) { return ('0x{0:X2}' -f $c) } else { return ('0x{0:X}' -f $c) }
}

function Get-BugcheckInfo($codeStr) {
    if ($BugchecksKb -and $codeStr -and $BugchecksKb.PSObject.Properties[$codeStr]) {
        return $BugchecksKb.PSObject.Properties[$codeStr].Value
    }
    return $null
}

function ConvertTo-HtmlText($s) {
    if ($null -eq $s) { return '' }
    $t = [string]$s
    $t = $t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    return $t
}

function Test-Elevated {
    Invoke-Safe {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } $false
}

function Get-EventXmlData($event) {
    $result = @{ Named = @{}; Values = @() }
    Invoke-Safe {
        $xml = [xml]$event.ToXml()
        foreach ($d in $xml.Event.EventData.Data) {
            if ($d -is [string]) {
                $result.Values += $d
            } else {
                $val = $d.'#text'
                $result.Values += $val
                if ($d.Name) { $result.Named[$d.Name] = $val }
            }
        }
    } | Out-Null
    return $result
}

function Get-EventSignal($LogName, $Id, $Provider, $Since) {
    # Returns { Items, Count, Readable }. Crucially distinguishes "query ran, 0 matches" (Readable=$true)
    # from "query FAILED / access denied / log missing" (Readable=$false). Get-WinEvent signals "no
    # matches" via a specific NoMatchingEventsFound error, so an empty result is NOT itself a failure.
    $filter = @{ LogName = $LogName; StartTime = $Since }
    if ($Id)       { $filter['Id'] = $Id }
    if ($Provider) { $filter['ProviderName'] = $Provider }
    try {
        $items = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
        [pscustomobject]@{ Items = $items; Count = $items.Count; Readable = $true }
    } catch {
        # NoMatchingEventsFound (FullyQualifiedErrorId) is the authoritative, locale-independent "0 matches"
        # signal; the message-text match is only a non-authoritative English fallback.
        $noMatch = ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') -or ($_.Exception.Message -match 'No events were found')
        [pscustomobject]@{ Items = @(); Count = 0; Readable = [bool]$noMatch }
    }
}

# ---------------------------------------------------------------------------
# Collectors (all read-only)
# ---------------------------------------------------------------------------
function Get-SystemSummary {
    $os   = Invoke-Safe { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    $cs   = Invoke-Safe { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $cpu  = Invoke-Safe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
    $bios = Invoke-Safe { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $lastBoot = $null; $uptimeText = 'unknown'
    if ($os -and $os.LastBootUpTime) {
        $lastBoot = $os.LastBootUpTime
        $u = (Get-Date) - $lastBoot
        $uptimeText = ('{0}d {1}h' -f $u.Days, $u.Hours)
    }

    # Read-only hardware inventory: GPU model, RAM running speed, and a best-effort XMP/DOCP-active
    # flag (DDR4 JEDEC base is <=2666 MT/s; a higher running speed implies an XMP/DOCP/EXPO profile).
    $gpu = Invoke-Safe { @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } @()
    $realGpu = @($gpu | Where-Object { $_.Name -and ([string]$_.Name) -notmatch 'Basic|Remote|Meta |Parsec|DameWare|Virtual|Mirror' })
    $gpuName = if ($realGpu.Count -gt 0) { ([string]$realGpu[0].Name).Trim() } elseif (@($gpu).Count -gt 0) { ([string]$gpu[0].Name).Trim() } else { '' }
    $mem = Invoke-Safe { @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) } @()
    $ramSpeed = 0; $ramRated = 0; $xmpActive = $false; $ratedAbove = $false
    foreach ($m in $mem) {
        $cfg = [int]$m.ConfiguredClockSpeed
        $rated = [int]$m.Speed
        if ($cfg -gt 0 -and $cfg -gt $ramSpeed) { $ramSpeed = $cfg }
        if ($rated -gt 0 -and $rated -gt $ramRated) { $ramRated = $rated }
        # XMP/DOCP/EXPO is active only when the running speed exceeds the SPD-rated base (per DIMM).
        # A flat threshold mislabels stock DDR5 (JEDEC 4800-5600) as overclocked.
        if ($cfg -gt 0 -and $rated -gt 0 -and $cfg -gt $rated) { $xmpActive = $true }
        # Inverse signal: the modules are rated clearly ABOVE their running speed -> headroom left idle.
        if ($cfg -gt 0 -and $rated -gt 0 -and ($rated - $cfg) -ge 100) { $ratedAbove = $true }
    }
    # "Possible free performance": NO XMP/DOCP/EXPO profile active AND either the modules are rated above
    # their running speed (definite headroom) OR RAM sits at a classic DDR4 JEDEC base (<=2666 MT/s - the
    # speeds an un-enabled XMP kit defaults to). Advisory only; the scorer surfaces it as a note, never a fault.
    $xmpOffSuspected = (-not $xmpActive) -and ($ratedAbove -or ($ramSpeed -gt 0 -and $ramSpeed -le 2666))

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        OS           = if ($os) { $os.Caption } else { 'unknown' }
        OSBuild      = if ($os) { $os.BuildNumber } else { '' }
        Manufacturer = if ($cs) { ([string]$cs.Manufacturer).Trim() } else { '' }
        Model        = if ($cs) { ([string]$cs.Model).Trim() } else { '' }
        CPU          = if ($cpu) { ([string]$cpu.Name).Trim() } else { '' }
        RAMGB        = if ($cs -and $cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }
        BiosSerial   = if ($bios) { ([string]$bios.SerialNumber).Trim() } else { '' }
        LastBoot     = $lastBoot
        UptimeText   = $uptimeText
        Gpu          = $gpuName
        RamModules   = @($mem).Count
        RamSpeed        = $ramSpeed
        RamRatedSpeed   = $ramRated
        XmpActive       = $xmpActive
        XmpOffSuspected = $xmpOffSuspected
        IsElevated      = Test-Elevated
    }
}

function Get-CrashEvents($since) {
    # Returns { Items, Readable }. Readable is false if EITHER System-log query failed to read - so the
    # scorer never presents "no crashes" as a clean bill when it actually couldn't read the log.
    $crashes = @()
    $readable = $true
    $sig1 = Get-EventSignal 'System' 1001 'Microsoft-Windows-WER-SystemErrorReporting' $since
    if (-not $sig1.Readable) { $readable = $false }
    foreach ($e in $sig1.Items) {
        $codeStr = $null; $dump = $null
        if ($e.Message) {
            $m = [regex]::Match($e.Message, '0x[0-9A-Fa-f]{8}')
            if ($m.Success) { $codeStr = Format-Bugcheck ([Convert]::ToInt64($m.Value, 16)) }
            $dm = [regex]::Match($e.Message, 'saved in:\s*(.+?\.dmp)')
            if ($dm.Success) { $dump = $dm.Groups[1].Value.Trim() }
        }
        $crashes += [pscustomobject]@{ Time = $e.TimeCreated; Source = 'BugCheck 1001'; BugcheckCode = $codeStr; DumpPath = $dump }
    }
    $sig41 = Get-EventSignal 'System' 41 'Microsoft-Windows-Kernel-Power' $since
    if (-not $sig41.Readable) { $readable = $false }
    foreach ($e in $sig41.Items) {
        $xd = Get-EventXmlData $e
        $bc = 0
        if ($xd.Named.ContainsKey('BugcheckCode')) { $bc = [int64]$xd.Named['BugcheckCode'] }
        $codeStr = $null
        if ($bc -ne 0) { $codeStr = Format-Bugcheck $bc }
        $crashes += [pscustomobject]@{ Time = $e.TimeCreated; Source = 'Kernel-Power 41'; BugcheckCode = $codeStr; DumpPath = $null }
    }
    [pscustomobject]@{ Items = @($crashes); Readable = $readable }
}

function Get-AppCrashEvents($since) {
    # Event ID 1000/1002 are reused by many providers for their own logging. Filter by the
    # specific Windows crash/hang providers so we don't count unrelated app log entries.
    # Readable is false if EITHER Application-log query failed, so the scorer never reads "no app
    # crashes" as clean when the log was actually unreadable.
    $items = @()
    $readable = $true
    $sets = @(
        @{ Provider = 'Application Error'; Id = 1000; Kind = 'crash' },
        @{ Provider = 'Application Hang';  Id = 1002; Kind = 'hang' }
    )
    foreach ($s in $sets) {
        $sig = Get-EventSignal 'Application' $s.Id $s.Provider $since
        if (-not $sig.Readable) { $readable = $false }
        foreach ($e in $sig.Items) {
            $data = Get-EventXmlData $e
            $app = if ($data.Values.Count -ge 1) { ([string]$data.Values[0]).Trim() } else { '' }
            $mod = if ($data.Values.Count -ge 4) { ([string]$data.Values[3]).Trim() } else { '' }
            $exc = if ($data.Values.Count -ge 7) { ([string]$data.Values[6]).Trim() } else { '' }
            # A real faulting-app name is a bare exe filename; skip anything multi-line/oversized.
            if ($app -match '[\r\n]' -or $app.Length -gt 64) { continue }
            $items += [pscustomobject]@{ Time = $e.TimeCreated; App = $app; Module = $mod; Exception = $exc; Kind = $s.Kind }
        }
    }
    [pscustomobject]@{ Items = @($items); Readable = $readable }
}

function Get-TdrCount($since) {
    $sig = Get-EventSignal 'System' 4101 $null $since
    [pscustomobject]@{ Count = $sig.Count; Readable = $sig.Readable }
}

function Get-GpuVendorEvents($since) {
    # Vendor GPU-driver reset/hang events (NVIDIA nvlddmkm, AMD amdkmdag, Intel igfx). Event 153
    # collides with the 'disk' provider, so we MUST filter by provider name.
    $providers = 'nvlddmkm', 'nvlddmkmoc', 'amdkmdag', 'amdwddmg', 'amdkmpfd', 'igfxn', 'igfx', 'igfxcuiservice'
    $sig = Get-EventSignal 'System' @(153, 14) $null $since
    $hits = @($sig.Items | Where-Object { $_.ProviderName -in $providers })
    $vendor = ''
    if ($hits.Count -gt 0) {
        $p = ([string]$hits[0].ProviderName).ToLower()
        if ($p -like 'nv*') { $vendor = 'NVIDIA' } elseif ($p -like 'amd*') { $vendor = 'AMD' } elseif ($p -like 'ig*') { $vendor = 'Intel' }
    }
    [pscustomobject]@{ Count = $hits.Count; Vendor = $vendor; Readable = $sig.Readable }
}

function Get-DumpFailureCount($since) {
    # volmgr 161 = "crash dump file creation failed". A loud clue: the machine died too fast to log.
    $sig = Get-EventSignal 'System' 161 'volmgr' $since
    [pscustomobject]@{ Count = $sig.Count; Readable = $sig.Readable }
}

function Get-DumpConfig {
    # READ-ONLY: the crash-dump policy from the registry, so we can tell the user when the next crash
    # would go uncaptured. CrashDumpEnabled: 0=none, 1=complete, 2=kernel, 3=small(minidump), 7=automatic.
    # AutoReboot: 1=auto-restart on (the PC reboots before you can read the stop code). We only REPORT this
    # and the click-path to change it - we NEVER write it (the read-only invariant). Reading this key needs
    # no elevation; if it fails, Readable=$false and the scorer stays silent (never nags on unknown config).
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $readable = $false; $cde = $null; $ar = $null
    try {
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        $readable = $true
        if ($null -ne $p.CrashDumpEnabled) { $cde = [int]$p.CrashDumpEnabled }
        if ($null -ne $p.AutoReboot)       { $ar = [int]$p.AutoReboot }
    } catch { $readable = $false }
    [pscustomobject]@{ CrashDumpEnabled = $cde; AutoReboot = $ar; Readable = $readable }
}

function Get-StorageEvents($since) {
    $sig = Get-EventSignal 'System' @(7, 11, 51, 153, 129) $null $since
    $items = @($sig.Items | Where-Object { $_.ProviderName -in 'disk', 'storahci', 'stornvme' })
    [pscustomobject]@{ Items = $items; Readable = $sig.Readable }
}

function Get-WheaCounts($since) {
    $sig = Get-EventSignal 'System' $null 'Microsoft-Windows-WHEA-Logger' $since
    $ev = $sig.Items
    [pscustomobject]@{
        Fatal     = @($ev | Where-Object { $_.Id -in 18, 20, 46 }).Count
        Corrected = @($ev | Where-Object { $_.Id -in 17, 19, 47 }).Count
        Total     = @($ev).Count
        Readable  = $sig.Readable
    }
}

function Get-UpdateFailures($since) {
    $sig = Get-EventSignal 'System' @(20, 25) 'Microsoft-Windows-WindowsUpdateClient' $since
    [pscustomobject]@{ Count = $sig.Count; Readable = $sig.Readable }
}

function Get-MemDiagFailed($since) {
    $sig = Get-EventSignal 'System' 1101 'Microsoft-Windows-MemoryDiagnostics-Results' $since
    [pscustomobject]@{ Failed = ($sig.Count -ge 1); Readable = $sig.Readable }
}

function Get-DriveHealth {
    $drives = @()
    $readable = $true
    $phys = @()
    try { $phys = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $readable = $false }
    foreach ($d in $phys) {
        $wear = $null; $temp = $null; $readErr = $null; $poh = $null; $relOk = $false
        $rc = Invoke-Safe { $d | Get-StorageReliabilityCounter -ErrorAction Stop }
        if ($rc) { $relOk = $true; $wear = $rc.Wear; $temp = $rc.Temperature; $readErr = $rc.ReadErrorsUncorrected; $poh = $rc.PowerOnHours }
        $drives += [pscustomobject]@{
            Name                  = $d.FriendlyName
            Media                 = [string]$d.MediaType
            SizeGB                = if ($d.Size) { [math]::Round($d.Size / 1GB, 0) } else { 0 }
            HealthStatus          = [string]$d.HealthStatus
            OperationalStatus     = ($d.OperationalStatus -join ',')
            Wear                  = $wear
            TempC                 = $temp
            ReadErrorsUncorrected = $readErr
            PowerOnHours          = $poh
            ReliabilityReadable   = $relOk
        }
    }
    [pscustomobject]@{ Items = @($drives); Readable = $readable }
}

function Get-VolumeInfo {
    $vols = @()
    $readable = $true
    $v = @()
    try { $v = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter }) } catch { $readable = $false }
    foreach ($x in $v) {
        if (-not $x.Size -or $x.Size -eq 0) { continue }
        $freePct = [math]::Round(($x.SizeRemaining / $x.Size) * 100, 0)
        $vols += [pscustomobject]@{
            Drive   = "$($x.DriveLetter):"
            Label   = [string]$x.FileSystemLabel
            FreeGB  = [math]::Round($x.SizeRemaining / 1GB, 0)
            SizeGB  = [math]::Round($x.Size / 1GB, 0)
            FreePct = $freePct
            Low     = ($freePct -lt 10 -or ($x.SizeRemaining / 1GB) -lt 10)
        }
    }
    [pscustomobject]@{ Items = @($vols); Readable = $readable }
}

function Get-ProblemCodeText($code) {
    switch ([int]$code) {
        1   { 'Not configured correctly (Code 1)' }
        3   { 'Driver corrupted or low on resources (Code 3)' }
        10  { 'Cannot start (Code 10)' }
        12  { 'Insufficient resources (Code 12)' }
        14  { 'Needs a restart (Code 14)' }
        18  { 'Drivers need reinstalling (Code 18)' }
        19  { 'Registry configuration corrupt (Code 19)' }
        28  { 'No driver installed (Code 28)' }
        31  { 'Driver not loading (Code 31)' }
        37  { 'Driver init failed (Code 37)' }
        39  { 'Driver missing or corrupt (Code 39)' }
        43  { 'Windows stopped it - device reported a problem (Code 43)' }
        45  { 'Not currently connected (Code 45)' }
        default { "Problem code $code" }
    }
}

function Get-ProblemDevices {
    $devs = @()
    $readable = $true
    $cand = @()
    # Widen beyond Status 'Error': also catch 'Degraded' (a device running with a fault) and 'Unknown'
    # devices that carry a non-zero Device Manager problem code. 'Error'/'Degraded' are genuine problem
    # states on their own; an 'Unknown'-status device counts only when it actually reports a problem code,
    # so a benign indeterminate-state device is not flagged. Read-only throughout.
    try { $cand = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' }) } catch { $readable = $false }
    foreach ($d in $cand) {
        $code = Invoke-Safe { (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop).Data }
        $codeNum = 0; if ($null -ne $code) { try { $codeNum = [int]$code } catch { $codeNum = 0 } }
        if ($d.Status -eq 'Error' -or $d.Status -eq 'Degraded' -or $codeNum -gt 0) {
            $devs += [pscustomobject]@{
                Name        = $d.FriendlyName
                Class       = [string]$d.Class
                Status      = [string]$d.Status
                ProblemCode = $code
                ProblemText = Get-ProblemCodeText $code
            }
        }
    }
    [pscustomobject]@{ Items = @($devs); Readable = $readable }
}

# ---------------------------------------------------------------------------
# Optional intake questionnaire (interactive; deterministic; NO new PII)
# ---------------------------------------------------------------------------
# A short, fixed-choice questionnaire whose answers the scorer consumes deterministically (the AI
# still never ranks). Stored as integer codes only - no free text, no personal data. Auto-skips on
# any non-interactive run (smoke test / CI / Quick-Assist-piped) so it can never block the pipeline.
function Test-Interactive {
    # True only when we can safely Read-Host. Fails SAFE (returns $false) so a non-interactive or
    # piped run (smoke test / CI / Quick Assist) skips the questions instead of blocking on input.
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected)        { return $false }
        return $true
    } catch { return $false }
}

function Get-IntakeQuestions {
    # Single source of truth for the questions: used both to ASK (Get-IntakeAnswers) and to LABEL
    # (Format-IntakeLines). Option order IS the integer code the scorer reads (1-based); 0 = skip.
    @(
        [pscustomobject]@{ Key = 'CrashBehavior'; Multi = $false; Text = 'When it crashes, what actually happens?'; Options = @(
            'The whole PC reboots or powers off (a full restart, sometimes a blue screen)',
            'Just the app closes to the desktop (the rest of Windows keeps running)',
            'It freezes / hangs and I have to hold the power button to recover') }
        [pscustomobject]@{ Key = 'When'; Multi = $false; Text = 'When do the crashes usually happen?'; Options = @(
            'During games or other heavy GPU load',
            'At idle or light use',
            'At startup, or waking from sleep',
            'Randomly, with no clear pattern') }
        [pscustomobject]@{ Key = 'Frequency'; Multi = $false; Text = 'How often does it happen?'; Options = @(
            'Several times a day',
            'About once a day',
            'A few times a week',
            'Weekly or less') }
        [pscustomobject]@{ Key = 'Tried'; Multi = $true; Text = 'What have you already tried? (pick any that apply)'; Options = @(
            'A clean Windows reinstall',
            'A clean GPU-driver reinstall with DDU',
            'Reseated RAM / GPU / cables',
            'Swapped in a known-good part to test',
            'Nothing yet') }
        [pscustomobject]@{ Key = 'Tweaks'; Multi = $true; Text = 'Any performance tweaks active? (pick any that apply)'; Options = @(
            'XMP / DOCP / EXPO memory profile on',
            'A manual CPU or GPU overclock',
            'An undervolt (CPU or GPU)',
            'Bone stock / all defaults',
            'Not sure') }
    )
}

function Get-IntakeAnswers {
    # Returns a pscustomobject of integer codes, or $null when nothing was answered / prompting is off.
    # CanPrompt is computed by the caller (honors -NoIntake + Test-Interactive); Reader is injectable so
    # the harness can unit-test parsing without a console (and prove the never-block guarantee).
    param([bool]$CanPrompt = $true, [scriptblock]$Reader)
    if (-not $CanPrompt) { return $null }
    $echo = -not $Reader
    if (-not $Reader) { $Reader = { Read-Host '  your choice' } }

    if ($echo) {
        Write-Host ''
        Write-Host 'A few optional questions - answers are stored as numbers only (no personal info) and' -ForegroundColor Cyan
        Write-Host 'they sharpen the ranking. Press Enter or 0 to skip any of them.' -ForegroundColor Cyan
    }

    # NB: keep the loop variable a distinctive name ($question, not $q). The Reader scriptblock is
    # invoked here via dynamic scope, so a terse local name could shadow a variable the reader relies on.
    $result = [ordered]@{}
    $any = $false
    foreach ($question in (Get-IntakeQuestions)) {
        if ($echo) {
            Write-Host ''
            Write-Host $question.Text -ForegroundColor White
            for ($i = 0; $i -lt $question.Options.Count; $i++) { Write-Host ('    {0}. {1}' -f ($i + 1), $question.Options[$i]) }
            Write-Host '    0. skip'
            if ($question.Multi) { Write-Host '    (one or more numbers, comma-separated)' -ForegroundColor DarkGray }
        }
        $raw = [string](& $Reader)
        $picked = @()
        foreach ($tok in ($raw -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $question.Options.Count) { $picked += $n }
        }
        $picked = @($picked | Select-Object -Unique)
        if ($question.Multi) {
            $result[$question.Key] = $picked
            if ($picked.Count -gt 0) { $any = $true }
        } else {
            $val = if ($picked.Count -gt 0) { [int]$picked[0] } else { 0 }
            $result[$question.Key] = $val
            if ($val -ne 0) { $any = $true }
        }
    }
    if (-not $any) { return $null }
    [pscustomobject]$result
}

function Format-IntakeLines($intake) {
    # Human-readable "question -> answer" lines for the report and the AI prompt (integer codes only;
    # no PII). Returns an empty array when there is no intake, so callers can guard on .Count.
    if (-not $intake) { return @() }
    $lines = @()
    foreach ($q in (Get-IntakeQuestions)) {
        $v = $intake.($q.Key)
        if ($q.Multi) {
            $picks = @(@($v) | Where-Object { $_ -ge 1 -and $_ -le $q.Options.Count })
            if ($picks.Count -gt 0) {
                $labels = @($picks | ForEach-Object { $q.Options[$_ - 1] })
                $lines += "$($q.Text) -> $($labels -join '; ')"
            }
        } else {
            $n = [int]$v
            if ($n -ge 1 -and $n -le $q.Options.Count) { $lines += "$($q.Text) -> $($q.Options[$n - 1])" }
        }
    }
    return , $lines
}

# ---------------------------------------------------------------------------
# Scorer (deterministic - this assigns tiers + confidence, never the AI)
# ---------------------------------------------------------------------------
function New-Culprit {
    param($Title, $TierClass, $Tier, $Confidence, [string[]]$For, [string[]]$Against, $ConfirmBy, $Search, [int]$Prominence = 0)
    [pscustomobject]@{
        Title      = $Title
        TierClass  = $TierClass
        Tier       = $Tier
        Confidence = $Confidence
        Prominence = $Prominence
        For        = @($For     | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
        Against    = @($Against | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
        ConfirmBy  = $ConfirmBy
        Search     = $Search
    }
}

function Get-TierRank($t) { if ($t -is [int]) { return $t }; if ($t -eq 'checklist') { return 3 }; return 9 }
function Get-ConfRank($c) { switch ($c) { 'High' { 0 } 'Medium' { 1 } 'Low' { 2 } 'Insufficient' { 3 } default { 4 } } }

function New-Diagnosis($data) {
    $culprits = @(); $ruledOut = @(); $notes = @()

    # Normalize the system-crash set. 1001 always carries a code; a BSOD also raises a
    # Kernel-Power 41 carrying the same code - dedupe those (same code within 2 minutes).
    $coded = @($data.Crashes | Where-Object { $_.BugcheckCode })
    $dedup = @()
    foreach ($c in ($coded | Sort-Object Time)) {
        $isDup = $false
        foreach ($d in $dedup) {
            if ($d.BugcheckCode -eq $c.BugcheckCode -and [math]::Abs(($d.Time - $c.Time).TotalMinutes) -le 2) { $isDup = $true; break }
        }
        if (-not $isDup) { $dedup += $c }
    }
    $codeGroups       = @($dedup | Group-Object BugcheckCode | Sort-Object Count -Descending)
    $crashCount       = @($dedup).Count
    $distinctCodes    = @($codeGroups).Count
    $codesPresent     = @($codeGroups | ForEach-Object { $_.Name })
    $unexplained      = @($data.Crashes | Where-Object { $_.Source -eq 'Kernel-Power 41' -and -not $_.BugcheckCode })
    $unexplainedCount = @($unexplained).Count

    # Consistency meta-rule (the core expert heuristic).
    if ($crashCount -ge 2) {
        if ($distinctCodes -eq 1) {
            $notes += "All $crashCount system crashes share one stop code ($($codeGroups[0].Name)) - a consistent pattern leans toward a single software/driver cause."
        } elseif ($distinctCodes -ge 3 -and $crashCount -ge 3) {
            $notes += "$crashCount crashes span $distinctCodes different stop codes - varied codes lean toward a hardware cause (RAM, power, or thermal)."
        }
    }

    # Performance advisory (NOT a fault, NEVER a culprit, NEVER moves a tier): RAM appears to be running
    # with no XMP/DOCP/EXPO profile - possible free performance left idle. Surfaced as a note only, so it
    # informs the human without touching the deterministic ranking (the inverse of the XMP-on For-line).
    if ($data.XmpOffSuspected) {
        $run = [int]$data.RamSpeed
        $rt  = [int]$data.RamRatedSpeed
        if ($rt -gt $run -and $run -gt 0) {
            $notes += "Performance tip (not a fault): RAM is running at $run MT/s but the modules are rated for $rt MT/s - no XMP/DOCP/EXPO profile is active. Enabling it in BIOS is free performance once you confirm it stays stable. This does not change the stability findings above."
        } else {
            $notes += "Performance tip (not a fault): RAM is running at $run MT/s with no XMP/DOCP/EXPO profile active - a common JEDEC base speed. If this kit is rated higher (check the label or invoice), enabling XMP/DOCP/EXPO in BIOS is possible free performance. This does not change the stability findings above."
        }
    }

    $badDrives = @($data.Drives | Where-Object { $_.HealthStatus -in 'Warning', 'Unhealthy' })

    # A. Failing drive - a confirmed fact, highest confidence.
    foreach ($bd in $badDrives) {
        $culprits += New-Culprit -Title "Drive health: $($bd.Name)" -TierClass 'drive' -Tier 1 -Confidence 'High' `
            -For @("Windows reports this drive's SMART health status as '$($bd.HealthStatus)'.") -Against @() `
            -ConfirmBy 'Back up important data now, then confirm with a full SMART read (CrystalDiskInfo / smartctl). Plan to replace the drive.' `
            -Search "$($bd.Name) SMART $($bd.HealthStatus) failing replace"
    }

    # B. WHEA / 0x124 - always hardware.
    if (($codesPresent -contains '0x124') -or $data.Whea.Fatal -ge 1) {
        $for = @()
        if ($codesPresent -contains '0x124') { $for += 'A 0x124 WHEA_UNCORRECTABLE_ERROR bugcheck occurred - the platform reported a hardware fault.' }
        if ($data.Whea.Fatal -ge 1)     { $for += "$($data.Whea.Fatal) fatal WHEA hardware-error event(s) were logged." }
        if ($data.Whea.Corrected -ge 1) { $for += "$($data.Whea.Corrected) corrected WHEA error(s) - often thermal/power or marginal hardware." }
        $culprits += New-Culprit -Title 'Hardware fault (CPU / RAM / motherboard / power)' -TierClass 'cpu' -Tier 1 -Confidence 'High' `
            -For $for -Against @() `
            -ConfirmBy 'Remove any CPU/RAM overclock or XMP/EXPO profile and re-test. Verify temperatures and that the PSU is adequate. WHEA errors are never fixed in software.' `
            -Search 'Windows 11 WHEA_UNCORRECTABLE_ERROR 0x124 troubleshooting'
    }

    # C. GPU display driver / GPU.
    $gpuFor = @(); $gpuSig = 0
    if ($data.TdrCount -ge 1) { $gpuFor += "$($data.TdrCount) display-driver timeout (TDR) event(s) recorded (Event 4101)."; $gpuSig += [math]::Min($data.TdrCount, 5) }
    $gpuCodes = @('0x116', '0x117', '0x119') | Where-Object { $codesPresent -contains $_ }
    if ($gpuCodes.Count -gt 0) { $gpuFor += "GPU bugcheck(s) present: $($gpuCodes -join ', ')."; $gpuSig += 3 }
    $gpuDevs = @($data.ProblemDevices | Where-Object { $_.Class -eq 'Display' })
    if ($gpuDevs.Count -gt 0) { $gpuFor += "Display adapter '$($gpuDevs[0].Name)' is flagged: $($gpuDevs[0].ProblemText)."; $gpuSig += 3 }
    $gpuVendCount = 0; $gpuVendor = ''
    if ($data.GpuVendorEvents) { $gpuVendCount = [int]$data.GpuVendorEvents.Count; $gpuVendor = [string]$data.GpuVendorEvents.Vendor }
    if ($gpuVendCount -ge 1) {
        $vlabel = if ($gpuVendor) { $gpuVendor } else { 'GPU' }
        $gpuFor += "$vlabel kernel driver reported $gpuVendCount GPU reset/hang event(s) (Event 153/14) - direct evidence of GPU instability, not just a circumstantial code."
        $gpuSig += [math]::Min($gpuVendCount, 4)
    }
    if ($gpuSig -ge 3) {
        # Independence-aware confidence. Count the DISTINCT evidence channels that fired (TDR, GPU
        # bugcheck, vendor driver event, Display problem-device) and let confidence rise with INDEPENDENT
        # corroboration - not with one channel stacking (a same-cluster signal corroborates but
        # is not fully independent). A LONE channel never reaches High (the lone-0x116 / lone-Display
        # discipline); the only single-channel High exceptions are repeated evidence over many events -
        # a TDR FLOOD (>=5) or a RECURRING GPU bugcheck (>=2 crashes), not a single flag.
        $gpuChannels = 0
        if ($data.TdrCount -ge 1)  { $gpuChannels++ }
        if ($gpuCodes.Count -gt 0) { $gpuChannels++ }
        if ($gpuVendCount -ge 1)   { $gpuChannels++ }
        if ($gpuDevs.Count -gt 0)  { $gpuChannels++ }
        $conf = 'Low'
        if ($gpuChannels -ge 2 -or $data.TdrCount -ge 5 -or ($gpuCodes.Count -gt 0 -and $crashCount -ge 2)) { $conf = 'High' }
        elseif ($data.TdrCount -ge 3 -or $gpuCodes.Count -gt 0 -or $gpuVendCount -ge 2 -or $gpuDevs.Count -gt 0) { $conf = 'Medium' }
        $against = @()
        # Only claim drives/WHEA "look clean" when those reads actually SUCCEEDED - an empty drive list
        # or a 0 WHEA total also occur when the read FAILED, which would falsely reassure (verify-pass leak).
        if ($data.DrivesReadable -and $data.Whea.Readable -and $badDrives.Count -eq 0 -and $data.Whea.Total -eq 0) { $against += 'Drive health and the hardware-error log look clean - this points at the driver/GPU rather than a failing drive or CPU underneath.' }
        $tier = if ($conf -eq 'High') { 1 } else { 2 }
        $gpuModel = [string]$data.GpuModel
        $gpuTitle  = if ($gpuModel) { "GPU display driver ($gpuModel)" } else { 'GPU display driver' }
        $gpuSearch = if ($gpuModel) { "Windows 11 $gpuModel display driver stopped responding TDR fix" } else { 'Windows 11 display driver stopped responding TDR fix' }
        $culprits += New-Culprit -Title $gpuTitle -TierClass 'gpu' -Tier $tier -Confidence $conf `
            -For $gpuFor -Against $against `
            -ConfirmBy 'Clean-reinstall the GPU driver with DDU (Display Driver Uninstaller), or roll back a version. If clean drivers do NOT stop it, swap-test the GPU (a failing card behaves exactly like this) - do not RMA on a guess.' `
            -Search $gpuSearch
    }

    # D. Memory / RAM.
    $memCodes = @('0x1A', '0x50', '0x4E', '0xC2', '0xC5') | Where-Object { $codesPresent -contains $_ }
    if ($memCodes.Count -gt 0 -or $data.MemDiagFailed) {
        $for = @(); $against = @()
        if ($memCodes.Count -gt 0) { $for += "Memory-related bugcheck(s): $($memCodes -join ', ')." }
        if ($data.MemDiagFailed)   { $for += 'Windows Memory Diagnostic recorded a memory error.' }
        if ($data.XmpActive)       { $for += 'RAM is running above standard JEDEC speed (an XMP/DOCP/EXPO overclock is active) - disable it and re-test before suspecting a bad stick.' }
        $conf = 'Low'
        if ($data.MemDiagFailed) { $conf = 'High' }
        elseif ($crashCount -ge 2 -and $distinctCodes -ge 2) { $conf = 'Medium' }
        else { $against += 'Only weak evidence so far - a single memory-style bugcheck can also be a driver corrupting memory. Needs a second corroborating crash to firm up.' }
        $tier = if ($conf -eq 'High') { 1 } else { 2 }
        $culprits += New-Culprit -Title 'Memory / RAM' -TierClass 'memory' -Tier $tier -Confidence $conf `
            -For $for -Against $against `
            -ConfirmBy 'Run MemTest86 (bootable) overnight, or Windows Memory Diagnostic. If memory is overclocked, disable XMP/EXPO first and re-test.' `
            -Search 'Windows 11 MEMORY_MANAGEMENT 0x1A test RAM MemTest86'
    }

    # E. Storage subsystem.
    $stCodes = @('0x7A', '0xF4', '0x154') | Where-Object { $codesPresent -contains $_ }
    $stEventCount = @($data.StorageEvents).Count
    if ($stCodes.Count -gt 0 -or $stEventCount -ge 3) {
        $for = @()
        if ($stCodes.Count -gt 0) { $for += "Storage-related bugcheck(s): $($stCodes -join ', ')." }
        if ($stEventCount -ge 1)  { $for += "$stEventCount disk/controller I/O error event(s) (disk 7/11/51/153, storahci 129)." }
        $conf = 'Low'
        if ($stCodes.Count -gt 0 -and $stEventCount -ge 3) { $conf = 'High' }
        elseif ($stEventCount -ge 3 -or $stCodes.Count -gt 0) { $conf = 'Medium' }
        $tier = if ($conf -eq 'High') { 1 } else { 2 }
        $culprits += New-Culprit -Title 'Storage subsystem (drive / cable / controller)' -TierClass 'storage' -Tier $tier -Confidence $conf `
            -For $for -Against @() `
            -ConfirmBy 'Check the drive and its SATA/NVMe cabling, run chkdsk and a SMART check, and update the storage-controller driver.' `
            -Search 'Windows 11 disk error event 153 KERNEL_DATA_INPAGE_ERROR drive failing'
    }

    # F. Consistent single-driver/software lean (only when codes are consistent and not hardware-classed).
    #    Emits tier 2 / Medium - a "possible" lead, NEVER a tier-1 prime suspect: the exact module is not
    #    named without a minidump (deep mode), so tier tracks confidence (DESIGN.md guardrail: tier 1 == High).
    if ($crashCount -ge 3 -and $distinctCodes -eq 1) {
        $code = $codeGroups[0].Name
        $info = Get-BugcheckInfo $code
        $cls  = if ($info) { $info.class } else { 'driver' }
        if ($cls -in 'driver', 'software') {
            $nm = if ($info) { $info.name } else { 'unknown' }
            $hint = if ($info) { $info.hint } else { '' }
            $culprits += New-Culprit -Title "A specific driver or software ($code $nm)" -TierClass 'driver' -Tier 2 -Confidence 'Medium' `
                -For @("All $crashCount crashes share the stop code $code - a consistent pattern points at one driver or software component.", $hint) `
                -Against @('The exact module is not named here without a minidump analysis (that is the optional deep mode).') `
                -ConfirmBy 'Recall what changed recently (a driver or Windows update, or a new app) and roll it back. Update or reinstall the most recently changed driver.' `
                -Search "Windows 11 $nm $code fix"
        }
    }

    # G. Unexpected restarts with no recorded cause - a CHECKLIST, never a verdict. Prominence scales
    #    with the count so a flood of hard-resets surfaces loudly, while confidence stays Insufficient.
    if ($unexplainedCount -ge 1) {
        # A few code-0 restarts over a long window is near-noise (KP41 also fires on user force-offs),
        # so only call it a "pattern" at a real cluster, and only raise the overclock line then.
        $headline = "$unexplainedCount unexpected restart(s) with no recorded cause"
        if ($unexplainedCount -ge 15)    { $headline = "$unexplainedCount unexpected restarts with no recorded cause - a frequent hard-reset pattern, the dominant symptom on this PC" }
        elseif ($unexplainedCount -ge 6) { $headline = "$unexplainedCount unexpected restarts with no recorded cause - a recurring hard-reset pattern" }
        $cfor = @("Kernel-Power 41 fired $unexplainedCount time(s) with bugcheck code 0 - Windows logged a hard restart but recorded no cause. A few of these over months is normal (an update reboot, a power blip, a manual force-off); a cluster is not.")
        if ($data.DumpFailures -ge 1) { $cfor += "Crash-dump creation failed $($data.DumpFailures) time(s) (volmgr Event 161) - the machine is dying too fast to finish writing a dump. That dump-write failure itself points at sudden power loss or a hard hang (PSU, GPU power, or thermal), not a clean software bug." }
        if ($data.XmpActive -and $unexplainedCount -ge 6) { $cfor += 'RAM is running above standard JEDEC speed (an XMP/DOCP/EXPO overclock is active) - test with it disabled; an unstable memory overclock is a common cause of no-dump restarts.' }
        $culprits += New-Culprit -Title $headline -TierClass 'power' -Tier 'checklist' -Confidence 'Insufficient' -Prominence $unexplainedCount `
            -For $cfor -Against @() `
            -ConfirmBy 'This is a symptom, not a diagnosis. Check in order: power (PSU, cables, wall outlet / surge protector), overheating (clean dust, verify temps), any overclock or XMP/DOCP profile, then enable full crash dumps (and disable auto-restart) so the next event is captured.' `
            -Search 'Windows 11 Kernel-Power 41 random restart no BSOD PSU thermal'
    }

    # H. Low disk space.
    foreach ($lv in @($data.Volumes | Where-Object { $_.Low })) {
        $culprits += New-Culprit -Title "Low disk space on $($lv.Drive)" -TierClass 'storage' -Tier 2 -Confidence 'High' `
            -For @("$($lv.Drive) has $($lv.FreeGB) GB free of $($lv.SizeGB) GB ($($lv.FreePct)%). Low free space causes slowdowns, failed updates, and instability.") -Against @() `
            -ConfirmBy 'Free up space (Storage Sense, clear temp and Downloads, uninstall unused apps). Aim for more than 10% free.' `
            -Search 'Windows 11 free up disk space slow performance'
    }

    # I. Problem devices (non-display; display feeds the GPU rule above).
    foreach ($pd in @($data.ProblemDevices | Where-Object { $_.Class -ne 'Display' })) {
        # Some flagged devices have no Class (e.g. an uninstalled-driver "Network Controller"); avoid the
        # leading-space "  device flagged" by falling back to a plain article.
        $clsLabel = if ([string]::IsNullOrWhiteSpace($pd.Class)) { 'A' } else { $pd.Class }
        $culprits += New-Culprit -Title "Problem device: $($pd.Name)" -TierClass 'driver' -Tier 2 -Confidence 'Medium' `
            -For @("$clsLabel device flagged in Device Manager: $($pd.ProblemText).") -Against @() `
            -ConfirmBy 'Update or reinstall this device''s driver and check it is seated/connected. Code 43/10 usually means a driver or the device itself.' `
            -Search "$($pd.Name) $($pd.ProblemText) Windows 11 fix"
    }

    # J. App-level crashes (separate lane from system crashes).
    $appGroups = @($data.AppCrashes | Where-Object { $_.Kind -eq 'crash' -and $_.App } | Group-Object App | Sort-Object Count -Descending)
    $topApp = $appGroups | Select-Object -First 1
    if ($topApp -and $topApp.Count -ge 3) {
        $mod = ($topApp.Group | Select-Object -First 1).Module
        $modText = ''
        if (-not [string]::IsNullOrWhiteSpace($mod)) { $modText = ", faulting module $mod" }
        # Developer runtimes/interpreters crash routinely during normal work (a script erroring out is not
        # a PC fault). Keep the signal honest but de-weighted - cap at Low and say why - so a pile of
        # python.exe exits never outranks a real system signal. Down-weight, NOT hide: it could still be
        # the very app the user is troubleshooting.
        $runtimes = @('python.exe', 'pythonw.exe', 'node.exe', 'ruby.exe', 'perl.exe')
        if ((([string]$topApp.Name).ToLower()) -in $runtimes) {
            $appConf = 'Low'
            $appAgainst = @("$($topApp.Name) is a developer runtime/interpreter - frequent crashes here are usually a script, package, or extension erroring out during normal use, not a PC hardware or system fault. Treat it as a lead only if $($topApp.Name) is the specific app you are troubleshooting.")
        } else {
            $appConf = 'Medium'
            $appAgainst = @('This is an app-level crash, not a system/BSOD - usually fixed by updating or reinstalling the app, not by touching hardware.')
        }
        $culprits += New-Culprit -Title "Application keeps crashing: $($topApp.Name)" -TierClass 'app' -Tier 2 -Confidence $appConf `
            -For @("$($topApp.Name) logged $($topApp.Count) crash event(s)$modText.") `
            -Against $appAgainst `
            -ConfirmBy "Update or reinstall $($topApp.Name). If it is graphics- or codec-heavy, update those drivers too." `
            -Search "$($topApp.Name) keeps crashing Windows 11 fix"
    }

    # K. Tool-ceiling handoff: when restarts pile up with no dumps, a read-only scan has hit its
    #    limit - say so honestly and point at the physical swap-tests that can actually confirm.
    if ($unexplainedCount -ge 5 -and ($crashCount -eq 0 -or $unexplainedCount -ge 3 * $crashCount)) {
        $culprits += New-Culprit -Title 'This pattern may need hands-on hardware testing' -TierClass 'handoff' -Tier 'checklist' -Confidence 'Insufficient' `
            -For @('Most of these restarts left no crash dump, so a read-only software scan has reached its limit. The remaining suspects - PSU health, GPU hardware, a no-POST - can only be confirmed physically, not from logs.') -Against @() `
            -ConfirmBy 'Cheap reversible checks, in order: (1) BIOS Load Optimized Defaults to drop any DOCP/XMP or CPU overclock; (2) swap-test the GPU (known-good card in, or this card in another PC) - a swap that fixes it is proof; do NOT buy or RMA on a guess; (3) swap-test the PSU if a spare exists; (4) if it ever fails to POST, read the motherboard CPU/DRAM/VGA/BOOT debug LEDs, reseat RAM and GPU, and clear CMOS; (5) watch temps in HWiNFO under load.' `
            -Search 'Windows 11 random restart no BSOD no dump PSU GPU swap test'
    }

    # L. Capture this next: when restarts are going unrecorded (dump-less KP41, or dump-writes failing)
    #    AND the dump policy would also drop the NEXT one (no dump saved, or auto-restart hiding the stop
    #    code), emit a first-class action card. Gated on evidence dumps are actually being missed, so it
    #    never nags a healthy box (auto-restart is ON by Windows default). Read-only: we report the
    #    click-path; the human applies it. Stays checklist/Insufficient - it captures data, never a verdict.
    $dc = $data.DumpConfig
    if ($dc -and $dc.Readable) {
        $noDumps    = ($null -ne $dc.CrashDumpEnabled -and $dc.CrashDumpEnabled -eq 0)
        $autoReboot = ($null -ne $dc.AutoReboot -and $dc.AutoReboot -eq 1)
        $missing    = ($unexplainedCount -ge 1 -or $data.DumpFailures -ge 1)
        if ($missing -and ($noDumps -or $autoReboot)) {
            $cfor = @()
            if ($noDumps)    { $cfor += 'Windows is set to NOT save a crash dump (Write debugging information = "(none)"), so a crash that DOES blue-screen leaves nothing to analyze.' }
            if ($autoReboot) { $cfor += 'Auto-restart is ON, so the PC reboots instantly on a blue screen - you never see the stop code.' }
            if ($unexplainedCount -ge 1)  { $cfor += "$unexplainedCount of these restarts recorded no cause - capturing the next crash is the best chance at a readable stop code (a true power-loss may still leave none, which is itself a clue pointing at power/thermal rather than software)." }
            if ($data.DumpFailures -ge 1) { $cfor += "Crash-dump creation already failed $($data.DumpFailures) time(s) (volmgr Event 161) - the machine is dying too fast to finish writing a dump." }
            $culprits += New-Culprit -Title 'Capture the next crash (dumps are not being saved)' -TierClass 'capture' -Tier 'checklist' -Confidence 'Insufficient' `
                -For $cfor -Against @() `
                -ConfirmBy 'Turn on crash capture so the next failure is recorded: press Win+R, run "SystemPropertiesAdvanced", then Startup and Recovery > Settings. Set "Write debugging information" to "Small memory dump (256 KB)" and UNCHECK "Automatically restart". Reproduce the crash, then re-run this tool - the next dump will carry the stop code.' `
                -Search 'Windows 11 enable minidump disable automatic restart startup and recovery'
        }
    }

    # ---- Optional user-reported intake (deterministic). It NEVER changes a tier or confidence - it
    #      only adds evidence lines / notes and retargets confirm steps, so every guardrail still holds
    #      (the measured signals keep driving the ranking; self-reported symptoms inform the narrative).
    #      $null when the user skipped or the run was non-interactive. Code meanings (1-based options
    #      from Get-IntakeQuestions): CrashBehavior 1=whole-PC reboot 2=app-closes 3=freeze;
    #      When 1=gaming/GPU-load 2=idle 3=startup 4=random; Tried 1=clean-install 2=DDU 3=reseat
    #      4=swapped-part 5=none; Tweaks 1=XMP 2=manual-OC 3=undervolt 4=stock 5=unsure.
    $intake = $data.Intake
    if ($intake) {
        $tried  = @($intake.Tried)
        $tweaks = @($intake.Tweaks)

        # (1) A clean Windows reinstall and/or DDU is already done and it still crashes -> the software,
        #     OS, and display-driver branches are effectively ruled out; weight shifts toward hardware.
        #     Also drop the now-redundant "do a DDU" GPU confirm step (it has been done).
        if (($tried -contains 1) -or ($tried -contains 2)) {
            $ruledLine = 'You report a clean Windows reinstall and/or a DDU driver wipe is already done and the symptoms persist - so software, OS, and display-driver causes are effectively ruled out. That shifts the weight toward hardware.'
            foreach ($c in $culprits) {
                if ($c.TierClass -eq 'gpu' -or $c.TierClass -eq 'driver') { $c.Against = @($c.Against) + $ruledLine }
                if ($c.TierClass -eq 'gpu') {
                    $c.ConfirmBy = 'The clean driver reinstall (DDU) is already done and it still crashes, so stop reinstalling drivers - swap-test the GPU instead (a known-good card in this PC, or this card in another PC). A swap that fixes it is proof; do not RMA on a guess.'
                }
            }
            $notes += 'User reports a clean Windows reinstall / DDU driver wipe was already done and crashes persist - the software and display-driver branches are treated as effectively ruled out below.'
        }

        # (2) What the crash looks like to the user: whole-PC reboot leans power/hardware; app-close
        #     leans application/driver; a hard freeze points at a hang to capture.
        switch ([int]$intake.CrashBehavior) {
            1 {
                foreach ($c in $culprits) {
                    if ($c.TierClass -in 'power', 'gpu', 'cpu', 'handoff') {
                        $c.For = @($c.For) + 'You report the WHOLE PC reboots (not just the app closing) - consistent with a power-delivery, GPU-hardware, or platform-level fault rather than an application bug.'
                    }
                }
            }
            2 {
                foreach ($c in $culprits) {
                    if ($c.TierClass -eq 'app') { $c.For = @($c.For) + 'Matches your report that the app closes to the desktop while the rest of Windows keeps running.' }
                }
                $notes += 'User reports the app closes to the desktop while the rest of the PC keeps running - that is an application-level fault, not a system crash/BSOD. Weight the app and driver suspects above the system-crash ones.'
            }
            3 {
                $notes += 'User reports the PC freezes/hangs and needs a hard power-off (no auto-reboot) - a hard hang most often points at the GPU/display driver, storage I/O, or thermal throttling. Capture the next one (enable a full crash dump; watch temps under load).'
            }
        }

        # (3) When the crashes happen - corroboration for load-driven causes (no new culprit either way).
        switch ([int]$intake.When) {
            1 {
                foreach ($c in $culprits) {
                    if ($c.TierClass -in 'gpu', 'power', 'cpu') {
                        $c.For = @($c.For) + 'You report crashes under gaming / high-GPU load - consistent with GPU, power-delivery, or thermal stress that only appears under load.'
                    }
                }
            }
            2 { $notes += 'User reports crashes at idle / light use - load-driven causes (thermal, power-under-load) are less likely; this leans toward a marginal component, a background driver, or an unstable idle power state.' }
            3 { $notes += 'User reports crashes at startup / waking from sleep - look first at boot and storage drivers, Fast Startup, and sleep/power-state handling.' }
        }

        # (4) An active manual overclock or undervolt is an uncontrolled variable - it must be removed
        #     before ANY hardware conclusion is trusted. (XMP/DOCP already has its own evidence line.)
        if (($tweaks -contains 2) -or ($tweaks -contains 3)) {
            $notes += 'Uncontrolled variable: you report a manual overclock and/or an undervolt is active. An unstable overclock or too-aggressive undervolt produces exactly these random crashes / WHEA errors / no-dump restarts. Reset to stock (BIOS Load Optimized Defaults; clear any Afterburner / Ryzen Master profile) and re-test before trusting ANY hardware conclusion here.'
        }
    }

    # Ruled out this pass - only list things actually CHECKED and clean. When a signal could not be
    # read (collector failure / access denied), say "not checked" as a neutral note, NEVER "clean".
    # (Evidence-quality accounting: absence of data must never read as a clean bill.)
    if (-not $data.CrashesReadable) {
        $notes += 'Crash history - the System event log could not be read this run, so an absence of crashes below is NOT a clean bill. Re-run (elevated if needed).'
    }
    $drivesPresent = @($data.Drives)
    if (-not $data.DrivesReadable) {
        $notes += 'Drive health - the drive list could not be read this run (Get-PhysicalDisk failed); drives were NOT checked.'
    } elseif ($drivesPresent.Count -gt 0 -and $badDrives.Count -eq 0) {
        # A Healthy rollup with unreadable detailed SMART (the default non-elevated run) is NOT a clean
        # bill - say so as a neutral note, never a green "ruled out". (DESIGN guardrail #4.)
        $unreadable = @($drivesPresent | Where-Object { -not $_.ReliabilityReadable })
        if ($unreadable.Count -eq 0) {
            $ruledOut += 'Drive health - all drives report SMART status Healthy.'
        } else {
            $notes += "Drive health - Windows reports basic status Healthy, but detailed SMART was not readable this run ($($unreadable.Count) of $($drivesPresent.Count) drive(s)); run elevated to confirm. This is not a clean bill of drive health."
        }
    }
    if (-not $data.VolumesReadable) {
        $notes += 'Disk space - volumes could not be read this run; disk space was NOT checked.'
    } elseif (@($data.Volumes).Count -gt 0 -and @($data.Volumes | Where-Object { $_.Low }).Count -eq 0) {
        $ruledOut += 'Disk space - no volume is critically low.'
    }
    if (-not $data.UpdatesReadable) {
        $notes += 'Windows Update - the update-failure log could not be read this run; update health was NOT checked.'
    } elseif ($data.UpdateFailures -eq 0) {
        $ruledOut += 'Windows Update - no recent update failures.'
    }
    if (-not $data.DevicesReadable) {
        $notes += 'Devices - Device Manager could not be read this run; problem devices were NOT checked.'
    } elseif (@($data.ProblemDevices).Count -eq 0) {
        $ruledOut += 'Devices - no problem devices in Device Manager.'
    }
    if (-not $data.Whea.Readable) {
        $notes += 'Hardware-error log (WHEA) - could not be read this run; NOT checked.'
    } elseif ($data.Whea.Total -eq 0) {
        $ruledOut += 'Hardware-error log (WHEA) - clean.'
    }

    # Culprit-only event signals (Slice B residual): these each feed a culprit, so a FAILED read is a
    # missed culprit (false-negative), not a false-clean - they never go in RuledOut. Surface it honestly
    # as one consolidated note so the absence of a GPU/storage/etc. culprit below is not mistaken for
    # "checked and clean". Default-readable, so a normal run says nothing here.
    $culpritUnreadable = @()
    if (-not $data.TdrReadable)          { $culpritUnreadable += 'GPU display-driver timeouts (Event 4101)' }
    if (-not $data.GpuVendorReadable)    { $culpritUnreadable += 'GPU vendor driver errors (Event 153/14)' }
    if (-not $data.StorageReadable)      { $culpritUnreadable += 'disk / controller I/O errors' }
    if (-not $data.DumpFailuresReadable) { $culpritUnreadable += 'crash-dump-write failures (volmgr 161)' }
    if (-not $data.AppCrashesReadable)   { $culpritUnreadable += 'application crashes' }
    if (-not $data.MemDiagReadable)      { $culpritUnreadable += 'memory-diagnostic results' }
    if ($culpritUnreadable.Count -gt 0) {
        $notes += "Some culprit signals could not be read this run ($($culpritUnreadable -join '; ')) - a related culprit may be UNDER-reported, so the absence of one below is not proof it is clean. (These event reads can fail when a log is busy or access is limited.)"
    }

    # Order by tier, then confidence, then prominence. A heavy flood of dump-less restarts gets an
    # effective rank of 1.5 so it floats ABOVE tier-2 culprits but stays BELOW a real tier-1 - while
    # its label stays checklist/Insufficient (prominence and confidence stay decoupled, per DESIGN.md).
    # Stamp a stable insertion index too: Sort-Object is NOT a stable sort on Windows PowerShell 5.1
    # (it is on PS 7), so two equally-ranked checklist cards could otherwise swap order between versions
    # (the dual-version gate caught exactly this on capture+handoff). The index is the final tiebreaker,
    # making the order deterministic and identical on both - falling back to the rules' natural order.
    $idx = 0
    foreach ($c in $culprits) {
        $sr = [double](Get-TierRank $c.Tier)
        if ($c.Tier -eq 'checklist' -and $c.TierClass -eq 'power' -and $c.Prominence -ge 10 -and ($crashCount -eq 0 -or $c.Prominence -ge 5 * $crashCount)) { $sr = 1.5 }
        $c | Add-Member -NotePropertyName SortRank -NotePropertyValue $sr -Force
        $c | Add-Member -NotePropertyName SortIndex -NotePropertyValue $idx -Force
        $idx++
    }
    $culprits = @($culprits | Sort-Object `
            @{ Expression = { $_.SortRank } }, `
            @{ Expression = { Get-ConfRank $_.Confidence } }, `
            @{ Expression = { - [int]$_.Prominence } }, `
            @{ Expression = { $_.SortIndex } })

    # AllReadable: every gated signal was actually read - the MAIN signals AND the culprit-only event
    # signals. The "came back clean" banner shows ONLY when true, so an unreadable GPU/storage/etc. read
    # can no longer flash "all clean" when we simply could not look (Slice B residual completion).
    $allReadable = ([bool]$data.CrashesReadable -and [bool]$data.DrivesReadable -and [bool]$data.VolumesReadable -and [bool]$data.UpdatesReadable -and [bool]$data.DevicesReadable -and [bool]$data.Whea.Readable -and `
            [bool]$data.TdrReadable -and [bool]$data.GpuVendorReadable -and [bool]$data.StorageReadable -and [bool]$data.DumpFailuresReadable -and [bool]$data.AppCrashesReadable -and [bool]$data.MemDiagReadable)

    [pscustomobject]@{
        Culprits         = $culprits
        RuledOut         = $ruledOut
        Notes            = $notes
        CrashCount       = $crashCount
        DistinctCodes    = $distinctCodes
        UnexplainedCount = $unexplainedCount
        BugcheckGroups   = $codeGroups
        AppCrashCount    = @($data.AppCrashes | Where-Object { $_.Kind -eq 'crash' }).Count
        CrashesReadable  = [bool]$data.CrashesReadable
        AllReadable      = $allReadable
        Intake           = $data.Intake
    }
}

# ---------------------------------------------------------------------------
# PII redaction (applied to the AI prompt by default - the report stays local)
# ---------------------------------------------------------------------------
function New-RedactionMap($sys) {
    $map = [ordered]@{}
    if ($sys.UserName)     { $map[[regex]::Escape($sys.UserName)] = '[USER_1]' }
    if ($sys.ComputerName) { $map[[regex]::Escape($sys.ComputerName)] = '[HOST_1]' }
    $serial = [string]$sys.BiosSerial
    if ($serial.Trim() -ne '' -and $serial -notmatch 'To Be Filled|Default string|System Serial|^0+$') {
        $map[[regex]::Escape($serial)] = '[SERIAL_1]'
    }
    return $map
}

function Protect-Text($text, $map) {
    if (-not $text) { return $text }
    $t = [string]$text
    foreach ($k in $map.Keys) { $t = $t -replace $k, $map[$k] }
    $t = [regex]::Replace($t, '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', '[MAC]')
    $t = [regex]::Replace($t, '\b(\d{1,3}\.){3}\d{1,3}\b', '[IP]')
    return $t
}

# ---------------------------------------------------------------------------
# AI prompt builder
# ---------------------------------------------------------------------------
function Build-AiPrompt($sys, $diag, $map, $redact) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('You are a senior Windows 11 PC repair technician. Below is a read-only diagnostic summary from a misbehaving PC, including a DETERMINISTIC, confidence-tiered list of likely culprits produced by a scorer. Do NOT re-rank it - keep the given order, tiers, and confidence. For each culprit in order, explain in plain English why it is implicated and the single cheapest next step to confirm it. If you disagree with the ranking or see something the scorer missed, raise it as a flagged question - do not silently reorder. Where evidence is marked insufficient, or a signal is noted as "could not be read" / "NOT checked", treat it as MISSING DATA (not clean) and say what to capture next instead of guessing. If a USER-REPORTED SYMPTOMS block is present below, treat it as ground truth from the machine''s owner and reconcile the deterministic signals with it.')
    [void]$sb.AppendLine('')
    $intakeLines = Format-IntakeLines $diag.Intake
    if (@($intakeLines).Count -gt 0) {
        [void]$sb.AppendLine('=== USER-REPORTED SYMPTOMS (treat as ground truth; reconcile the signals below with these) ===')
        foreach ($l in $intakeLines) { [void]$sb.AppendLine(" - $l") }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('=== SYSTEM ===')
    [void]$sb.AppendLine("OS: $($sys.OS) build $($sys.OSBuild)")
    [void]$sb.AppendLine("Machine: $($sys.Manufacturer) $($sys.Model)")
    [void]$sb.AppendLine("CPU: $($sys.CPU)  |  RAM: $($sys.RAMGB) GB  |  uptime: $($sys.UptimeText)")
    if ($sys.Gpu) { [void]$sb.AppendLine("GPU: $($sys.Gpu)") }
    $ramLine = "RAM detail: $($sys.RamModules) module(s)"
    if ($sys.RamSpeed -gt 0) { $ramLine += " @ $($sys.RamSpeed) MT/s" }
    if ($sys.XmpActive)      { $ramLine += ' (XMP/DOCP profile appears active)' }
    [void]$sb.AppendLine($ramLine)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("=== CRASH SUMMARY (last $Days days) ===")
    if ($diag.CrashesReadable) {
        [void]$sb.AppendLine("System crashes: $($diag.CrashCount) across $($diag.DistinctCodes) distinct stop code(s).")
    } else {
        [void]$sb.AppendLine("System crashes: NOT READABLE this run - the System event log could not be read, so a 0 here is missing data, not a clean count.")
    }
    foreach ($g in $diag.BugcheckGroups) {
        $info = Get-BugcheckInfo $g.Name
        $nm = if ($info) { $info.name } else { 'unknown' }
        [void]$sb.AppendLine(" - $($g.Name) $nm  x$($g.Count)")
    }
    if ($diag.UnexplainedCount -ge 1) { [void]$sb.AppendLine("Unexpected restarts with no recorded cause (Kernel-Power 41, code 0): $($diag.UnexplainedCount)") }
    if ($diag.AppCrashCount -ge 1)    { [void]$sb.AppendLine("Application-level crash events: $($diag.AppCrashCount)") }
    foreach ($n in $diag.Notes) { [void]$sb.AppendLine("Note: $n") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== RANKED CULPRITS (deterministic scorer - explain and pressure-test in order; do not reorder) ===')
    if (@($diag.Culprits).Count -eq 0) {
        [void]$sb.AppendLine('None - no instability signals found in the window.')
    } else {
        $rank = 1
        foreach ($c in $diag.Culprits) {
            [void]$sb.AppendLine("$rank. [$($c.Confidence)] $($c.Title)")
            foreach ($f in $c.For)     { [void]$sb.AppendLine("     for: $f") }
            foreach ($a in $c.Against)  { [void]$sb.AppendLine("     against: $a") }
            [void]$sb.AppendLine("     confirm: $($c.ConfirmBy)")
            $rank++
        }
    }
    # Negative evidence: what was checked this pass and came back clean. Hand it to the AI so it does not
    # re-suggest an already-cleared cause. (Distinct from the "could not be read / NOT checked" notes
    # above, which are missing data - those still need capturing; these are genuinely ruled out.)
    if (@($diag.RuledOut).Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('=== ALREADY CHECKED THIS PASS (ruled out - do NOT re-recommend these without a specific new reason) ===')
        foreach ($r in $diag.RuledOut) { [void]$sb.AppendLine(" - $r") }
    }
    $text = $sb.ToString()
    if ($redact) { $text = Protect-Text $text $map }
    return $text
}

# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------
function Get-TierLabel($t) {
    # Returns HTML-safe label text (uses the &middot; entity so the source stays ASCII for PS 5.1).
    if ($t -eq 'checklist') { return "can't determine &middot; checklist" }
    if ($t -eq 1) { return 'tier 1 &middot; prime suspect' }
    if ($t -eq 2) { return 'tier 2 &middot; possible' }
    return 'lead'
}
function Get-ConfClass($c) { switch ($c) { 'High' { 'c-high' } 'Medium' { 'c-med' } 'Low' { 'c-low' } default { 'c-ins' } } }

function Render-Html($sys, $diag) {
    $genTime = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $elev = if ($sys.IsElevated) { 'elevated' } else { 'standard (some detailed SMART/device data needs elevation)' }

    $css = @'
<style>
:root{--bg:#faf9f7;--card:#fff;--ink:#1f1d1a;--muted:#6b6862;--line:#e7e4dd;
--amber:#854f0b;--amberbg:#faeeda;--blue:#0c447c;--bluebg:#e6f1fb;--gray:#444441;--graybg:#f1efe8;
--green:#27500a;--greenbg:#eaf3de;--red:#791f1f;--redbg:#fcebeb;}
@media (prefers-color-scheme:dark){:root{--bg:#1a1916;--card:#232120;--ink:#f0eee9;--muted:#a8a39a;--line:#34322c;
--amber:#fac775;--amberbg:#3a2c12;--blue:#9cc6f3;--bluebg:#11243a;--gray:#cfccc4;--graybg:#2a2824;
--green:#bde08f;--greenbg:#1c2912;--red:#f2a3a3;--redbg:#2e1414;}}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--ink);font-family:'Segoe UI',system-ui,sans-serif;line-height:1.6;
margin:0;padding:28px 18px;}
.wrap{max-width:760px;margin:0 auto}
h1{font-size:22px;font-weight:600;margin:0}
.sub{color:var(--muted);font-size:13px;margin:4px 0 0}
.badges{margin:14px 0 22px}
.badge{display:inline-block;font-size:12px;padding:4px 10px;border-radius:8px;margin-right:8px}
.b-green{background:var(--greenbg);color:var(--green)}
.b-blue{background:var(--bluebg);color:var(--blue)}
.section-label{font-size:13px;font-weight:600;color:var(--muted);margin:26px 0 10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:12px}
.card-top{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap}
.tier-tag{font-size:11px;padding:3px 8px;border-radius:8px;background:var(--graybg);color:var(--gray)}
.tier-1{background:var(--amberbg);color:var(--amber)}
.tier-check{background:var(--bluebg);color:var(--blue)}
.conf{font-size:12px;padding:3px 9px;border-radius:8px}
.c-high{background:var(--amberbg);color:var(--amber)}
.c-med{background:var(--bluebg);color:var(--blue)}
.c-low{background:var(--graybg);color:var(--gray)}
.c-ins{background:var(--bluebg);color:var(--blue)}
.title{font-size:15px;font-weight:600;margin:0 0 8px}
.ev{font-size:13.5px;margin:3px 0}
.ev .lbl{color:var(--muted)}
.for .mk{color:var(--green);font-weight:600}
.ag .mk{color:var(--red);font-weight:600}
.confirm{font-size:13.5px;margin-top:9px;padding-top:9px;border-top:1px solid var(--line)}
.confirm .lbl{color:var(--muted)}
.search{font-size:12.5px;margin-top:7px;color:var(--blue);word-break:break-word}
.ruled{background:var(--greenbg);border-radius:8px;padding:12px 16px;font-size:13.5px;color:var(--green)}
.ruled ul{margin:6px 0 0;padding-left:18px}
.note{background:var(--bluebg);color:var(--blue);border-radius:8px;padding:10px 14px;font-size:13.5px;margin-bottom:10px}
table{width:100%;border-collapse:collapse;font-size:13px}
td{padding:5px 0;border-bottom:1px solid var(--line);vertical-align:top}
td.k{color:var(--muted);width:42%}
.foot{margin-top:26px;padding-top:14px;border-top:1px solid var(--line);font-size:13px;color:var(--muted)}
.mono{font-family:Consolas,'Courier New',monospace}
.clean{background:var(--greenbg);color:var(--green);border-radius:12px;padding:18px;font-size:15px;text-align:center}
</style>
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>Second Opinion report</title>')
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</head><body><div class="wrap">')
    [void]$sb.AppendLine('<h1>Second Opinion</h1>')
    [void]$sb.AppendLine("<p class=""sub"">$(ConvertTo-HtmlText $sys.ComputerName) &middot; last $Days days &middot; generated $genTime &middot; run $elev</p>")
    [void]$sb.AppendLine('<div class="badges"><span class="badge b-green">read-only &middot; nothing changed</span><span class="badge b-blue">ai-prompt.txt &middot; key identifiers removed</span></div>')
    [void]$sb.AppendLine('<div class="note">Sharing note: this report (report.html) is NOT redacted - it shows your PC name and hardware, so share it only with the person helping you. For public help or pasting into an AI, use <span class="mono">out\ai-prompt.txt</span> instead (your username, PC name, and BIOS serial are removed - best-effort, not guaranteed).</div>')

    # Summary note line
    $summary = "$($diag.CrashCount) system crash(es) across $($diag.DistinctCodes) stop code(s)"
    if ($diag.UnexplainedCount -ge 1) { $summary += ", $($diag.UnexplainedCount) unexplained restart(s)" }
    if ($diag.AppCrashCount -ge 1)    { $summary += ", $($diag.AppCrashCount) app crash event(s)" }
    [void]$sb.AppendLine("<div class=""note"">$(ConvertTo-HtmlText $summary) in the window.</div>")
    foreach ($n in $diag.Notes) { [void]$sb.AppendLine("<div class=""note"">$(ConvertTo-HtmlText $n)</div>") }

    # What the user reported (optional intake) - treated as ground truth, reconciled with the signals.
    $intakeLines = Format-IntakeLines $diag.Intake
    if (@($intakeLines).Count -gt 0) {
        [void]$sb.AppendLine('<div class="section-label">What you reported</div><div class="card">')
        foreach ($l in $intakeLines) { [void]$sb.AppendLine("<p class=""ev""><span class=""lbl"">&bull;</span> $(ConvertTo-HtmlText $l)</p>") }
        [void]$sb.AppendLine('<p class="ev"><span class="lbl">Treated as ground truth and reconciled with the measured signals below.</span></p>')
        [void]$sb.AppendLine('</div>')
    }

    if (@($diag.Culprits).Count -eq 0) {
        if ($diag.AllReadable) {
            [void]$sb.AppendLine('<div class="clean">No instability signals found in this window. The checks below came back clean.</div>')
        } else {
            [void]$sb.AppendLine('<div class="note">No culprits to rank - but one or more checks could not be read this run, so this is NOT a clean bill. See the notes above and re-run (elevated if needed).</div>')
        }
    } else {
        [void]$sb.AppendLine('<div class="section-label">Likely culprits, ranked</div>')
        foreach ($c in $diag.Culprits) {
            $tierClass = 'tier-tag'
            if ($c.Tier -eq 1) { $tierClass += ' tier-1' } elseif ($c.Tier -eq 'checklist') { $tierClass += ' tier-check' }
            [void]$sb.AppendLine('<div class="card">')
            [void]$sb.AppendLine("<div class=""card-top""><span class=""$tierClass"">$(Get-TierLabel $c.Tier)</span><span class=""conf $(Get-ConfClass $c.Confidence)"">confidence: $($c.Confidence.ToLower())</span></div>")
            [void]$sb.AppendLine("<p class=""title"">$(ConvertTo-HtmlText $c.Title)</p>")
            foreach ($f in $c.For)    { [void]$sb.AppendLine("<p class=""ev for""><span class=""mk"">+</span> <span class=""lbl"">for:</span> $(ConvertTo-HtmlText $f)</p>") }
            foreach ($a in $c.Against) { [void]$sb.AppendLine("<p class=""ev ag""><span class=""mk"">&minus;</span> <span class=""lbl"">against:</span> $(ConvertTo-HtmlText $a)</p>") }
            [void]$sb.AppendLine("<p class=""confirm""><span class=""lbl"">confirm by:</span> $(ConvertTo-HtmlText $c.ConfirmBy)</p>")
            if ($c.Search) { [void]$sb.AppendLine("<p class=""search"">search: $(ConvertTo-HtmlText $c.Search)</p>") }
            [void]$sb.AppendLine('</div>')
        }
    }

    if (@($diag.RuledOut).Count -gt 0) {
        [void]$sb.AppendLine('<div class="section-label">Ruled out this pass</div><div class="ruled"><ul>')
        foreach ($r in $diag.RuledOut) { [void]$sb.AppendLine("<li>$(ConvertTo-HtmlText $r)</li>") }
        [void]$sb.AppendLine('</ul></div>')
    }

    # System table
    [void]$sb.AppendLine('<div class="section-label">System</div><div class="card"><table>')
    $ramText = "$($sys.RAMGB) GB"
    if ($sys.RamSpeed -gt 0) { $ramText += " - $($sys.RamSpeed) MT/s" }
    if ($sys.XmpActive)      { $ramText += ' (XMP/DOCP active)' }
    $rows = @(
        @('OS', "$($sys.OS) build $($sys.OSBuild)"),
        @('Machine', "$($sys.Manufacturer) $($sys.Model)"),
        @('CPU', $sys.CPU)
    )
    if ($sys.Gpu) { $rows += , @('GPU', $sys.Gpu) }
    $rows += , @('RAM', $ramText)
    $rows += , @('Uptime', $sys.UptimeText)
    foreach ($r in $rows) { [void]$sb.AppendLine("<tr><td class=""k"">$(ConvertTo-HtmlText $r[0])</td><td>$(ConvertTo-HtmlText $r[1])</td></tr>") }
    [void]$sb.AppendLine('</table></div>')

    # Drives table
    if (@($diag) -and @($script:LastDrives).Count -gt 0) {
        [void]$sb.AppendLine('<div class="section-label">Drives</div><div class="card"><table>')
        foreach ($d in $script:LastDrives) {
            $wear = if ($null -ne $d.Wear) { "$($d.Wear)% wear" } elseif (-not $d.ReliabilityReadable) { 'detailed SMART not exposed' } else { 'wear n/a' }
            [void]$sb.AppendLine("<tr><td class=""k"">$(ConvertTo-HtmlText $d.Name) ($(ConvertTo-HtmlText $d.Media), $($d.SizeGB) GB)</td><td>$(ConvertTo-HtmlText $d.HealthStatus) &middot; $(ConvertTo-HtmlText $wear)</td></tr>")
        }
        [void]$sb.AppendLine('</table></div>')
    }

    [void]$sb.AppendLine('<div class="foot">This is a read-only second opinion, not a verdict. Confirm before acting. To go deeper, paste <span class="mono">out\ai-prompt.txt</span> (key identifiers removed, best-effort) into ChatGPT or Claude. The full report.html is NOT redacted - keep it between you and your helper.</div>')
    [void]$sb.AppendLine('</div></body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# When dot-sourced (e.g. by the test harness: . .\Invoke-SecondOpinion.ps1) every function above is
# defined in the caller but no collector runs - so New-Diagnosis can be unit-tested against fixtures.
# Direct execution (.\Invoke-SecondOpinion.ps1 / -File) continues into the read-only pipeline below.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host 'Second Opinion - read-only diagnostic.' -ForegroundColor Cyan
# Optional intake FIRST (so the user answers, then watches the scan). Auto-skips when -NoIntake is set
# or the run is non-interactive, so a piped / Quick-Assist / CI run never blocks here.
$intake = Get-IntakeAnswers -CanPrompt:((-not $NoIntake) -and (Test-Interactive))
Write-Host ''
Write-Host 'Collecting (read-only)...' -ForegroundColor Cyan
$since = (Get-Date).AddDays(-$Days)
$sys = Get-SystemSummary

$crashSig = Get-CrashEvents $since
$driveSig = Get-DriveHealth
$volSig   = Get-VolumeInfo
$devSig   = Get-ProblemDevices
$updSig   = Get-UpdateFailures $since
$appSig   = Get-AppCrashEvents $since
$tdrSig   = Get-TdrCount $since
$gpuVSig  = Get-GpuVendorEvents $since
$dumpSig  = Get-DumpFailureCount $since
$stSig    = Get-StorageEvents $since
$memSig   = Get-MemDiagFailed $since
$script:LastDrives = $driveSig.Items
$data = [pscustomobject]@{
    Crashes              = $crashSig.Items
    CrashesReadable      = $crashSig.Readable
    AppCrashes           = $appSig.Items
    AppCrashesReadable   = $appSig.Readable
    TdrCount             = $tdrSig.Count
    TdrReadable          = $tdrSig.Readable
    GpuVendorEvents      = $gpuVSig
    GpuVendorReadable    = $gpuVSig.Readable
    DumpFailures         = $dumpSig.Count
    DumpFailuresReadable = $dumpSig.Readable
    DumpConfig           = Get-DumpConfig
    StorageEvents        = $stSig.Items
    StorageReadable      = $stSig.Readable
    Whea                 = Get-WheaCounts $since
    UpdateFailures       = $updSig.Count
    UpdatesReadable      = $updSig.Readable
    MemDiagFailed        = $memSig.Failed
    MemDiagReadable      = $memSig.Readable
    Drives               = $driveSig.Items
    DrivesReadable       = $driveSig.Readable
    Volumes              = $volSig.Items
    VolumesReadable      = $volSig.Readable
    ProblemDevices       = $devSig.Items
    DevicesReadable      = $devSig.Readable
    GpuModel             = $sys.Gpu
    XmpActive            = $sys.XmpActive
    XmpOffSuspected      = $sys.XmpOffSuspected
    RamSpeed             = $sys.RamSpeed
    RamRatedSpeed        = $sys.RamRatedSpeed
    Intake               = $intake
}

$diag = New-Diagnosis $data

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$reportPath = Join-Path $OutDir 'report.html'
$promptPath = Join-Path $OutDir 'ai-prompt.txt'

$html = Render-Html $sys $diag
Set-Content -Path $reportPath -Value $html -Encoding UTF8

$redact = -not $NoRedact
if (-not $redact) {
    Write-Host ''
    Write-Host 'WARNING: -NoRedact is set - ai-prompt.txt will contain UNREDACTED identifiers (username, hostname, BIOS serial). Keep it local; do not paste it into a public chat.' -ForegroundColor Yellow
}
$map = New-RedactionMap $sys
$prompt = Build-AiPrompt $sys $diag $map $redact
Set-Content -Path $promptPath -Value $prompt -Encoding UTF8

Write-Host ''
Write-Host ("  {0} system crash(es), {1} unexplained restart(s), {2} culprit(s) ranked." -f $diag.CrashCount, $diag.UnexplainedCount, @($diag.Culprits).Count)
Write-Host "  Report:  $reportPath" -ForegroundColor Green
Write-Host "  Prompt:  $promptPath  (redacted: $redact)" -ForegroundColor Green
if ($OpenReport) { Invoke-Safe { Start-Process $reportPath } | Out-Null }
