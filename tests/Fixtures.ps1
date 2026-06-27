<#
  Regression fixtures for the deterministic scorer (New-Diagnosis).

  Defined as PowerShell objects rather than JSON so we avoid ConvertFrom-Json's empty-array /
  datetime round-trip quirks. Get-Fixtures returns an ordered map name -> $data object (the exact
  shape the main pipeline hands to New-Diagnosis). Get-Fingerprint reduces a diagnosis to a stable,
  human-diffable text line set used as the golden (tests/golden/<name>.expected.txt).

  The gpu-failure-01 fixture is a representative GPU-failure case (a 0x116 TDR cluster + dump-less restarts).
  Dot-sourced by Run-Fixtures.ps1. Read-only; defines functions only.
#>

$script:FxBase = [datetime]'2026-06-22T18:00:00'

function _arr($x) { if ($null -eq $x) { , @() } else { , @($x) } }
function _crash($min, $src, $code) { [pscustomobject]@{ Time = $script:FxBase.AddMinutes($min); Source = $src; BugcheckCode = $code; DumpPath = $null } }
function _drive($name, $media, $gb, $health, $rel) { [pscustomobject]@{ Name = $name; Media = $media; SizeGB = $gb; HealthStatus = $health; OperationalStatus = 'OK'; Wear = $null; TempC = $null; ReadErrorsUncorrected = $null; PowerOnHours = $null; ReliabilityReadable = $rel } }
function _app($app, $mod) { [pscustomobject]@{ Time = $script:FxBase; App = $app; Module = $mod; Exception = '0xc0000005'; Kind = 'crash' } }
function _whea($f, $c, $t, $readable = $true) { [pscustomobject]@{ Fatal = $f; Corrected = $c; Total = $t; Readable = $readable } }
function _rd($v) { if ($null -ne $v) { [bool]$v } else { $true } }
function _gpuv($count, $vendor) { [pscustomobject]@{ Count = $count; Vendor = $vendor } }
function _vol($d, $free, $size, $low) { [pscustomobject]@{ Drive = $d; Label = ''; FreeGB = $free; SizeGB = $size; FreePct = [math]::Round(($free / $size) * 100, 0); Low = $low } }
function _intake($crash, $when, $freq, $tried, $tweaks) { [pscustomobject]@{ CrashBehavior = [int]$crash; When = [int]$when; Frequency = [int]$freq; Tried = @($tried); Tweaks = @($tweaks) } }
function _dumpcfg($cde, $ar, $readable = $true) { [pscustomobject]@{ CrashDumpEnabled = $cde; AutoReboot = $ar; Readable = $readable } }
function _pdev($name, $class, $code, $text, $status = 'Error') { [pscustomobject]@{ Name = $name; Class = $class; Status = $status; ProblemCode = $code; ProblemText = $text } }
function _sig($count, $readable = $true) { [pscustomobject]@{ Items = @(); Count = [int]$count; Readable = [bool]$readable } }
function _dirty($unexpected, $boot = 0, $readable = $true) { [pscustomobject]@{ Items = @(); Count = ([int]$unexpected + [int]$boot); UnexpectedCount = [int]$unexpected; BootCount = [int]$boot; Readable = [bool]$readable } }
function _live($codes, $readable = $true) {
    $c = @($codes | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        Items    = @()
        Count    = @($c).Count
        GpuCount = @($c | Where-Object { $_ -in '117', '141' }).Count
        UsbCount = @($c | Where-Object { $_ -eq '144' }).Count
        Codes    = @($c)
        Readable = [bool]$readable
    }
}

function _perf($throttle, $lowmem, $throttleReadable = $true, $lowmemReadable = $true) {
    [pscustomobject]@{
        Requested         = $true
        ThrottleCount     = [int]$throttle
        ThrottleReadable  = [bool]$throttleReadable
        LowMemoryCount    = [int]$lowmem
        LowMemoryReadable = [bool]$lowmemReadable
        Readable          = ([bool]$throttleReadable -and [bool]$lowmemReadable)
    }
}

function _data($h) {
    # Readability flags default to $true (a successful collection) unless a fixture overrides them.
    [pscustomobject]@{
        Crashes              = _arr $h.Crashes
        CrashesReadable      = _rd $h.CrashesReadable
        AppCrashes           = _arr $h.AppCrashes
        AppCrashesReadable   = _rd $h.AppCrashesReadable
        TdrCount             = [int]$h.TdrCount
        TdrReadable          = _rd $h.TdrReadable
        GpuVendorEvents      = if ($h.GpuVendorEvents) { $h.GpuVendorEvents } else { _gpuv 0 '' }
        GpuVendorReadable    = _rd $h.GpuVendorReadable
        DumpFailures         = [int]$h.DumpFailures
        DumpFailuresReadable = _rd $h.DumpFailuresReadable
        StorageEvents        = _arr $h.StorageEvents
        StorageReadable      = _rd $h.StorageReadable
        Whea                 = if ($h.Whea) { $h.Whea } else { _whea 0 0 0 }
        UpdateFailures       = [int]$h.UpdateFailures
        UpdatesReadable      = _rd $h.UpdatesReadable
        MemDiagFailed        = [bool]$h.MemDiagFailed
        MemDiagReadable      = _rd $h.MemDiagReadable
        Drives          = _arr $h.Drives
        DrivesReadable  = _rd $h.DrivesReadable
        Volumes         = _arr $h.Volumes
        VolumesReadable = _rd $h.VolumesReadable
        ProblemDevices  = _arr $h.ProblemDevices
        DevicesReadable = _rd $h.DevicesReadable
        GpuModel        = [string]$h.GpuModel
        XmpActive       = [bool]$h.XmpActive
        XmpOffSuspected = [bool]$h.XmpOffSuspected
        RamSpeed        = [int]$h.RamSpeed
        RamRatedSpeed   = [int]$h.RamRatedSpeed
        Intake          = if ($null -ne $h.Intake) { $h.Intake } else { $null }
        DumpConfig      = if ($null -ne $h.DumpConfig) { $h.DumpConfig } else { $null }
        DeepDump        = if ($null -ne $h.DeepDump) { $h.DeepDump } else { $null }
        DirtyShutdowns       = if ($null -ne $h.DirtyShutdowns) { $h.DirtyShutdowns } else { _dirty 0 0 }
        LiveKernelEvents     = if ($null -ne $h.LiveKernelEvents) { $h.LiveKernelEvents } else { _live @() }
        StorageCorroborators = if ($null -ne $h.StorageCorroborators) { $h.StorageCorroborators } else { _sig 0 }
        SmartPredictiveFailures = if ($null -ne $h.SmartPredictiveFailures) { $h.SmartPredictiveFailures } else { _sig 0 }
        # Performance defaults to $null (perf smoke test NOT requested) so every existing fixture is byte-neutral.
        Performance          = if ($null -ne $h.Performance) { $h.Performance } else { $null }
    }
}

function Get-Fixtures {
    $f = [ordered]@{}

    # gpu-failure-01: the real case. 2x 0x116 (>2 min apart, so they don't dedupe) + 37x Kernel-Power 41
    # code-0; 3 app crashes across DIFFERENT apps (so no app-cluster node, matching his real report);
    # two Healthy drives with detailed SMART not readable (non-elevated run); everything else clean.
    $gpuFailure01Crashes = @( (_crash -2880 'BugCheck 1001' '0x116'), (_crash 0 'BugCheck 1001' '0x116') )
    for ($i = 1; $i -le 37; $i++) { $gpuFailure01Crashes += (_crash (-($i * 30)) 'Kernel-Power 41' $null) }
    $f['gpu-failure-01'] = _data @{
        Crashes         = $gpuFailure01Crashes
        AppCrashes      = @( (_app 'discord.exe' 'd3d11.dll'), (_app 'chrome.exe' ''), (_app 'steam.exe' '') )
        GpuVendorEvents = (_gpuv 2 'NVIDIA')
        DumpFailures    = 1
        Drives          = @( (_drive 'WD Blue SN570 1TB' 'SSD' 932 'Healthy' $false), (_drive 'WDC WD40EZAZ' 'HDD' 3726 'Healthy' $false) )
        Volumes         = @( (_vol 'C:' 312 931 $false) )
        GpuModel        = 'NVIDIA GeForce RTX 3060 Ti'
        XmpActive       = $true
    }

    # lone-0x116: a single TDR bugcheck with no other GPU signal must stay Medium, never High.
    $f['lone-0x116'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x116') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # rapid-repeat-same-code: two real WER BugCheck 1001 records with the same code inside two minutes
    # are two crashes, not a WER/KP41 double-log. This must preserve CrashCount=2 so recurring GPU
    # bugchecks reach tier 1 / High instead of being silently demoted.
    $f['rapid-repeat-same-code'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x116'), (_crash 1 'BugCheck 1001' '0x116') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # same-crash-wer-kp41: one WER BugCheck 1001 and one coded Kernel-Power 41 of the same code inside
    # the two-minute window are a double-log of the same crash and must still count once.
    $f['same-crash-wer-kp41'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x116'), (_crash 1 'Kernel-Power 41' '0x116') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # varied-codes: 3 crashes / 3 distinct codes must fire the hardware-leaning variance note and
    # NOT a single-driver claim (rule F needs distinctCodes==1). 0x1A/0x50 also raise Memory/RAM.
    $f['varied-codes'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x50'), (_crash -200 'BugCheck 1001' '0x1A'), (_crash -400 'BugCheck 1001' '0xD1') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # consistent-driver-crashes: 3 crashes ALL on one driver-class stop code (0xD1) -> rule F fires (the
    # consistent single-driver lean). It must be a tier-2 / Medium "possible" lead, NEVER a tier-1 prime
    # suspect - we cannot name the exact driver without a minidump, so tier tracks confidence. Complements
    # varied-codes (distinct codes -> NO single-driver claim). Spaced >2 min apart so none dedupe.
    $f['consistent-driver-crashes'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0xD1'), (_crash -200 'BugCheck 1001' '0xD1'), (_crash -400 'BugCheck 1001' '0xD1') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # whea-fatal: a fatal WHEA hardware error must yield Hardware-fault High even with Healthy drives.
    $f['whea-fatal'] = _data @{
        Whea    = (_whea 1 0 1)
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # blank-smart: a Healthy drive whose detailed SMART is not readable. Locks current behavior;
    # the "detailed SMART not exposed" honesty lives in the rendered drive table, not New-Diagnosis.
    $f['blank-smart'] = _data @{
        Drives  = @( (_drive 'USB Enclosure Disk' 'SSD' 1000 'Healthy' $false) )
        Volumes = @( (_vol 'C:' 400 931 $false) )
    }

    # only-kp41: nothing but 37 dump-less restarts -> a single checklist node, CrashCount 0.
    $kp = @(); for ($i = 1; $i -le 37; $i++) { $kp += (_crash (-($i * 30)) 'Kernel-Power 41' $null) }
    $f['only-kp41'] = _data @{ Crashes = $kp }

    # lone-storage: a single storage bugcheck must NOT become tier 1 "prime suspect".
    $f['lone-storage'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x7A') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # few-kp41-healthy: a few code-0 restarts on an otherwise-clean box (with XMP genuinely on) must
    # stay calm - no "recurring pattern" language, no overclock scare, never High, no go-physical card.
    $kp3 = @(); for ($i = 1; $i -le 3; $i++) { $kp3 += (_crash (-($i * 120)) 'Kernel-Power 41' $null) }
    $f['few-kp41-healthy'] = _data @{
        Crashes   = $kp3
        XmpActive = $true
        Drives    = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes   = @( (_vol 'C:' 200 465 $false) )
    }

    # collection-failed: several collectors could not read their signal. NONE of those may appear as a
    # green "clean / ruled out" - each must surface as a "not checked" note instead (evidence quality).
    # A present-but-unreadable drive + volume make the "nothing ruled clean" assertion exercise all gates.
    $f['collection-failed'] = _data @{
        CrashesReadable = $false
        UpdatesReadable = $false
        DevicesReadable = $false
        VolumesReadable = $false
        DrivesReadable  = $false
        Whea            = (_whea 0 0 0 $false)
        Drives          = @( (_drive 'Unreadable Disk' 'SSD' 500 'Healthy' $true) )
        Volumes         = @( (_vol 'C:' 200 465 $false) )
    }

    # partial-readable: crash log read fine (0 crashes) but a secondary collector failed and no culprit
    # fired - the green clean banner must be SUPPRESSED (AllReadable false), not shown below "not checked".
    $f['partial-readable'] = _data @{
        DrivesReadable = $false
        Whea           = (_whea 0 0 0 $false)
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # partial-readable-gpu: a fired GPU culprit while drives/WHEA are UNREADABLE - the culprit must not
    # claim "drive health and the hardware-error log look clean" off failed reads.
    $f['partial-readable-gpu'] = _data @{
        TdrCount       = 6
        DrivesReadable = $false
        Whea           = (_whea 0 0 0 $false)
        GpuModel       = 'NVIDIA GeForce RTX 4070'
    }

    # gpu-failure-01-intake: the gpu-failure-01 data PLUS a deterministic intake (whole-PC reboot, under gaming
    # load, clean Windows reinstall + DDU already done, DOCP/XMP on). The clean-install answer must add
    # the "software effectively ruled out" evidence to the GPU node and drop the now-redundant DDU
    # confirm step; the XMP-only tweak must NOT raise the manual-OC/undervolt note; and tier/confidence
    # must be unchanged (intake never moves the ranking).
    $f['gpu-failure-01-intake'] = _data @{
        Crashes         = $gpuFailure01Crashes
        AppCrashes      = @( (_app 'discord.exe' 'd3d11.dll'), (_app 'chrome.exe' ''), (_app 'steam.exe' '') )
        GpuVendorEvents = (_gpuv 2 'NVIDIA')
        DumpFailures    = 1
        Drives          = @( (_drive 'WD Blue SN570 1TB' 'SSD' 932 'Healthy' $false), (_drive 'WDC WD40EZAZ' 'HDD' 3726 'Healthy' $false) )
        Volumes         = @( (_vol 'C:' 312 931 $false) )
        GpuModel        = 'NVIDIA GeForce RTX 3060 Ti'
        XmpActive       = $true
        Intake          = (_intake 1 1 1 @(1, 2) @(1))
    }

    # intake-oc: a single 0x124 WHEA bugcheck (-> Hardware High; the documented single-event exception)
    # on a box the user reports is BOTH manually overclocked AND undervolted. The uncontrolled-variable
    # note MUST fire (an active OC/undervolt invalidates any hardware verdict until it is reset to stock),
    # and intake must NOT change that verdict.
    $f['intake-oc'] = _data @{
        Crashes = @( (_crash 0 'BugCheck 1001' '0x124') )
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
        Intake  = (_intake 1 1 2 @(5) @(2, 3))
    }

    # intake-appclose: the user reports the APP closes to the desktop (not a whole-system crash) and one
    # app crashes repeatedly. Intake must lean app/driver (the "application-level fault" note), away from
    # a system-crash framing.
    $f['intake-appclose'] = _data @{
        AppCrashes = @( (_app 'game.exe' 'anticheat.dll'), (_app 'game.exe' 'anticheat.dll'), (_app 'game.exe' 'anticheat.dll') )
        Drives     = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes    = @( (_vol 'C:' 200 465 $false) )
        Intake     = (_intake 2 1 1 @(5) @(4))
    }

    # capture-dumps: dump-less restarts on a box whose dump policy would also drop the NEXT crash (no
    # dump saved + auto-restart on). The "Capture the next crash" card MUST fire (checklist/Insufficient,
    # never a verdict) so the user enables minidumps before the next failure.
    $kpCap = @(); for ($i = 1; $i -le 8; $i++) { $kpCap += (_crash (-($i * 60)) 'Kernel-Power 41' $null) }
    $f['capture-dumps'] = _data @{
        Crashes    = $kpCap
        DumpConfig = (_dumpcfg 0 1)
        Drives     = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes    = @( (_vol 'C:' 200 465 $false) )
    }

    # capture-good-config: the SAME dump-less restarts but a healthy dump policy (minidumps on,
    # auto-restart off). The capture card must NOT fire - we never nag when capture is already set up.
    $f['capture-good-config'] = _data @{
        Crashes    = $kpCap
        DumpConfig = (_dumpcfg 3 0)
        Drives     = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes    = @( (_vol 'C:' 200 465 $false) )
    }

    # app-runtime-noise: a developer runtime (python.exe) crashing repeatedly is normal dev activity, not
    # a PC fault - it must be DE-WEIGHTED to Low (not Medium) and carry the "runtime" caveat, so it never
    # outranks a real system signal. (A real app like game.exe in intake-appclose stays Medium.)
    $appRt = @(); for ($i = 1; $i -le 10; $i++) { $appRt += (_app 'python.exe' 'MSVCP140.dll') }
    $f['app-runtime-noise'] = _data @{
        AppCrashes = $appRt
        Drives     = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes    = @( (_vol 'C:' 200 465 $false) )
    }

    # device-no-class: a flagged device with NO Class (e.g. an uninstalled-driver Network Controller)
    # must render "A device flagged ...", never a leading-space "  device flagged ...".
    $f['device-no-class'] = _data @{
        ProblemDevices = @( (_pdev 'Network Controller' '' 28 'No driver installed (Code 28)') )
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # culprit-signals-unreadable: the MAIN signals read fine (clean) but several culprit-only event reads
    # FAILED (TDR / storage / mem-diag). Those feed culprits, so a failed read is a missed culprit, not a
    # clean bill: a consolidated "may be UNDER-reported" note must fire, and the clean banner must be
    # suppressed (AllReadable false) even though no culprit fired and the main signals are clean.
    $f['culprit-signals-unreadable'] = _data @{
        TdrReadable     = $false
        StorageReadable = $false
        MemDiagReadable = $false
        Drives          = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes         = @( (_vol 'C:' 200 465 $false) )
    }

    # lone-display-device: a single flagged Display adapter (Code 43) with NO other GPU channel must NOT
    # reach tier 1 / High - one channel is not enough (mirrors lone-0x116). It lands at tier 2 / Medium.
    # (Slice 6 closed this hole; the rules.json design workflow surfaced it.)
    $f['lone-display-device'] = _data @{
        ProblemDevices = @( (_pdev 'NVIDIA GeForce RTX 3060 Ti' 'Display' 43 'Windows stopped it - device reported a problem (Code 43)') )
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # gpu-two-channel: a Display problem-device PLUS a GPU bugcheck = two INDEPENDENT channels -> High /
    # tier 1. Locks that confidence rises with independent corroboration, and that the lone-display
    # demotion does NOT also suppress a genuinely corroborated GPU fault.
    $f['gpu-two-channel'] = _data @{
        Crashes        = @( (_crash 0 'BugCheck 1001' '0x116') )
        ProblemDevices = @( (_pdev 'NVIDIA GeForce RTX 3060 Ti' 'Display' 43 'Windows stopped it - device reported a problem (Code 43)') )
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # gpuhw-tdr-vendor: TWO independent GPU channels (a TDR pattern + vendor driver reset/hang events) with NO
    # bugcheck. The driver node reaches High (>=2 channels); the SEPARATE GPU-hardware node fires at tier 2 /
    # Medium (the card is a ranked possibility, never a verdict) and - because drives/WHEA are readable AND
    # clean - carries the honest "no logged hardware fault yet" against-line. Locks the non-bugcheck
    # multi-channel raise path AND that the hardware node never reaches tier 1 / High in v0.
    $f['gpuhw-tdr-vendor'] = _data @{
        TdrCount        = 3
        GpuVendorEvents = (_gpuv 2 'NVIDIA')
        GpuModel        = 'NVIDIA GeForce RTX 3060 Ti'
        Drives          = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes         = @( (_vol 'C:' 200 465 $false) )
    }

    # gpuhw-tdr-only: a single-channel TDR FLOOD (6 timeouts, nothing else). The driver node reaches High on
    # TdrCount>=5, but this is a DRIVER-ONLY pattern - one channel is not enough to suspect the CARD - so the
    # GPU-hardware node must NOT fire. Honest abstention: a pile of display-driver timeouts is most often a bad
    # driver, not a dying card. (The conservative companion to partial-readable-gpu's same single-channel flood.)
    $f['gpuhw-tdr-only'] = _data @{
        TdrCount = 6
        GpuModel = 'NVIDIA GeForce RTX 4070'
        Drives   = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes  = @( (_vol 'C:' 200 465 $false) )
    }

    # gpuhw-unreadable-whea: TWO GPU channels (a TDR pattern + a flagged Display adapter) DO fire the hardware
    # node, but the drive and WHEA reads FAILED this run. The node must NOT claim the hardware-error log "is
    # clean" off a failed read (evidence-quality / DESIGN guardrail #6: absence is never a clean bill) - the
    # WHEA-clean against-line is gated on Whea.Readable and must be ABSENT here, and the node stays tier 2/Medium.
    $f['gpuhw-unreadable-whea'] = _data @{
        TdrCount       = 2
        ProblemDevices = @( (_pdev 'NVIDIA GeForce RTX 3070' 'Display' 43 'Windows stopped it - device reported a problem (Code 43)') )
        GpuModel       = 'NVIDIA GeForce RTX 3070'
        DrivesReadable = $false
        Whea           = (_whea 0 0 0 $false)
    }

    # memdiag-zero-crash: a Windows Memory Diagnostic failure is a hardware FACT -> High even with zero
    # crashes (the documented single-event exception, like WHEA / drive-health). Previously unfixtured.
    $f['memdiag-zero-crash'] = _data @{
        MemDiagFailed = $true
        Drives        = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes       = @( (_vol 'C:' 200 465 $false) )
    }

    # multi-bad-drive: two failing drives each get their OWN tier-1 / High culprit (rule A is a per-item
    # emitter); locks that the per-drive cards render AND order deterministically (the Slice 2 SortIndex
    # fix, exercised across PS 5.1 + 7).
    $f['multi-bad-drive'] = _data @{
        Drives  = @( (_drive 'WD Blue SN570 1TB' 'SSD' 932 'Warning' $true), (_drive 'Seagate ST2000DM' 'HDD' 1863 'Unhealthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # degraded-device: a non-display device in a NON-'Error' problem state (Status 'Degraded' + a real
    # problem code) - the kind Get-ProblemDevices now surfaces (widened beyond Status='Error'). The scorer
    # must still raise a tier-2/Medium problem-device lead (it keys off the device problem, not the status).
    $f['degraded-device'] = _data @{
        ProblemDevices = @( (_pdev 'Realtek PCIe GbE Controller' 'Net' 31 'Driver not loading (Code 31)' 'Degraded') )
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # xmp-off: a clean machine whose RAM sits at a JEDEC base (2133 MT/s) rated for more (3200), with no
    # XMP/DOCP/EXPO profile active. The "possible free performance" advisory must fire as a NOTE only -
    # never a culprit, never a tier. (A representative stutter case; the inverse of the XMP-on flag.)
    $f['xmp-off'] = _data @{
        XmpOffSuspected = $true
        RamSpeed        = 2133
        RamRatedSpeed   = 3200
        Drives          = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes         = @( (_vol 'C:' 200 465 $false) )
    }

    # whea-corrected: corrected/non-fatal WHEA events with NO fatal and no 0x124 - rule B does not fire,
    # so there is no culprit, and (Total>0) the WHEA "clean" ruled-out also does not fire. Before the
    # Observed channel this VANISHED and the box read clean (the verified false-clean). Now it must
    # surface as an Observed weak signal AND suppress the clean banner. (Codex risk #1 + workflow.)
    $f['whea-corrected'] = _data @{
        Whea    = (_whea 0 12 12)
        Drives  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes = @( (_vol 'C:' 200 465 $false) )
    }

    # subthreshold-storage: 2 disk/controller I/O events, below the >=3 threshold for a storage culprit
    # and with no storage bugcheck. Must surface as Observed (seen, not enough), not vanish into clean.
    $f['subthreshold-storage'] = _data @{
        StorageEvents = @( 'disk-7', 'disk-153' )
        Drives        = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes       = @( (_vol 'C:' 200 465 $false) )
    }

    # update-failures: nonzero Windows Update failures - previously neither ruled-out (only 0 was) nor a
    # culprit, so they vanished. Now an Observed weak signal.
    $f['update-failures'] = _data @{
        UpdateFailures = 3
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # dirty-shutdown-alone: EventLog 6008 is real instability context, but by itself it is only Observed.
    $f['dirty-shutdown-alone'] = _data @{
        DirtyShutdowns = (_dirty 2 2)
        Drives         = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes        = @( (_vol 'C:' 200 465 $false) )
    }

    # dirty-shutdown-ranked: the same dirty-shutdown marker can support an already-ranked power/hard-reset
    # checklist node, but it must not change the node's checklist tier or Insufficient confidence.
    $dirtyKp = @(); for ($i = 1; $i -le 6; $i++) { $dirtyKp += (_crash (-($i * 30)) 'Kernel-Power 41' $null) }
    $f['dirty-shutdown-ranked'] = _data @{
        Crashes        = $dirtyKp
        DirtyShutdowns = (_dirty 2 2)
    }

    # livekernel-alone: LiveKernelEvent reports are recovered/non-fatal hardware-driver hiccups, not crashes.
    $f['livekernel-alone'] = _data @{
        LiveKernelEvents = (_live @('141', '144'))
        Drives           = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes          = @( (_vol 'C:' 200 465 $false) )
    }

    # livekernel-ranked: LiveKernelEvent 141 can support an already-ranked GPU node, but cannot move it.
    $f['livekernel-ranked'] = _data @{
        Crashes          = @( (_crash 0 'BugCheck 1001' '0x116') )
        LiveKernelEvents = (_live @('141'))
        Drives           = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes          = @( (_vol 'C:' 200 465 $false) )
    }

    # storage-corroborator-alone: Ntfs 55 / disk 157 are visible weak signals when no storage node exists.
    $f['storage-corroborator-alone'] = _data @{
        StorageCorroborators = (_sig 2)
        Drives               = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes              = @( (_vol 'C:' 200 465 $false) )
    }

    # storage-corroborator-ranked: storage/filesystem corroborators add a For line to the storage node only.
    $f['storage-corroborator-ranked'] = _data @{
        Crashes              = @( (_crash 0 'BugCheck 1001' '0x7A') )
        StorageCorroborators = (_sig 1)
        Drives               = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes              = @( (_vol 'C:' 200 465 $false) )
    }

    # smart52-alone: disk Event 52 is urgent to verify, but still not a lone tier-1/High drive verdict.
    $f['smart52-alone'] = _data @{
        SmartPredictiveFailures = (_sig 1)
        Drives                  = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes                 = @( (_vol 'C:' 200 465 $false) )
    }

    # smart52-ranked: disk Event 52 supports an already-ranked drive-health node without changing it.
    $f['smart52-ranked'] = _data @{
        SmartPredictiveFailures = (_sig 1)
        Drives                  = @( (_drive 'Generic SSD' 'SSD' 500 'Warning' $true) )
        Volumes                 = @( (_vol 'C:' 200 465 $false) )
    }

    # corroborators-unreadable: failed corroborator reads suppress the clean banner and say under-reported.
    $f['corroborators-unreadable'] = _data @{
        DirtyShutdowns           = (_dirty 0 0 $false)
        LiveKernelEvents         = (_live @() $false)
        StorageCorroborators     = (_sig 0 $false)
        SmartPredictiveFailures  = (_sig 0 $false)
        Drives                   = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes                  = @( (_vol 'C:' 200 465 $false) )
    }

    # blind-run: most CORE collectors unreadable (a locked-down / busy box where reads fail). The headline
    # must say MISSING DATA (severity 'blind') and BlindRun must be true - never imply a clean result.
    $f['blind-run'] = _data @{
        CrashesReadable = $false
        DrivesReadable  = $false
        VolumesReadable = $false
        UpdatesReadable = $false
        Whea            = (_whea 0 0 0 $false)
    }

    # --- Opt-in performance smoke test (-PerformanceSmokeTest). All five set Performance (which the default
    #     path leaves $null). They lock: throttling/low-memory ride as Observed/For-line, NEVER a culprit or
    #     tier; a clean scan says so (not a clean bill); an unreadable scan is NOT-checked, not clean.

    # perf-throttle-observed: a firmware-throttle CLUSTER (>=5) with no hardware/power node to attach to
    # surfaces as an Observed weak signal (NOT a culprit), and suppresses the clean banner.
    $f['perf-throttle-observed'] = _data @{
        Performance = (_perf 8 0)
    }

    # perf-throttle-corroborates: throttling alongside a ranked hardware node (here the WHEA-fatal cpu node)
    # adds a corroborating For-line to that node at ANY count - and must NOT move its tier/confidence, and must
    # NOT also emit a lone Observed line. Compared against the whea-fatal baseline by the guardrail.
    $f['perf-throttle-corroborates'] = _data @{
        Whea        = (_whea 1 0 1)
        Drives      = @( (_drive 'Generic SSD' 'SSD' 500 'Healthy' $true) )
        Volumes     = @( (_vol 'C:' 200 465 $false) )
        Performance = (_perf 3 0)
    }

    # perf-lowmem: Windows-diagnosed low-virtual-memory events surface as an Observed weak signal (never a
    # culprit) and suppress the clean banner.
    $f['perf-lowmem'] = _data @{
        Performance = (_perf 0 4)
    }

    # perf-clean: the test ran, both signals readable and zero - this is NOT a clean bill of health, so the
    # honest-abstention caveat note must be present, with NO Observed perf line and the perf readability rows
    # shown as readable.
    $f['perf-clean'] = _data @{
        Performance = (_perf 0 0)
    }

    # perf-unreadable: both perf reads failed - NOT checked, not clean. Must raise the could-not-be-read note,
    # set AllReadable false (clean banner suppressed), and never land in RuledOut.
    $f['perf-unreadable'] = _data @{
        Performance = (_perf 0 0 $false $false)
    }

    # empty: a clean machine -> zero culprits.
    $f['empty'] = _data @{}

    return $f
}

function Get-Fingerprint($diag) {
    $lines = @()
    $lines += "counts crashes=$($diag.CrashCount) distinct=$($diag.DistinctCodes) unexplained=$($diag.UnexplainedCount) appcrash=$($diag.AppCrashCount)"
    foreach ($c in @($diag.Culprits)) {
        $prom = ''
        if ($c.PSObject.Properties['Prominence'] -and [int]$c.Prominence -gt 0) { $prom = " prom=$($c.Prominence)" }
        $lines += "culprit | $($c.Title) | $($c.TierClass) | $($c.Tier) | $($c.Confidence)$prom"
    }
    foreach ($n in @($diag.Notes))    { $lines += "note | $n" }
    foreach ($o in @($diag.Observed)) { $lines += "observed | $o" }
    foreach ($r in @($diag.RuledOut)) { $lines += "ruled | $r" }
    return ($lines -join "`n")
}
