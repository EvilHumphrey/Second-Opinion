#
# PSScriptAnalyzer settings for Second Opinion - the lint gate (.github/workflows/lint.yml).
#
# Philosophy: run the full default rule set (security + correctness best practices a trust-critical,
# read-only tool wants), MINUS the handful of rules that fight this project's deliberate design, PLUS
# explicit Windows PowerShell 5.1 compatibility checks (syntax + commands/parameters + .NET types)
# that machine-enforce a core invariant.
#
# Run it the way CI does:
#   Invoke-ScriptAnalyzer -Path src,tests -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
#
@{
    # Start from every built-in rule, then subtract below. New analyzer releases that add rules will
    # surface here automatically (fail-loud) rather than being silently skipped.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # This is a user-facing CLI. Coloured terminal output via Write-Host IS the UX - it is not
        # logging that belongs on the information stream. Switching to Write-Output/Write-Information
        # would change behaviour, not improve it.
        'PSAvoidUsingWriteHost'

        # Information-level only. Positional args (Join-Path $a $b, [regex]::Match $s $p) are idiomatic
        # and readable throughout; demanding -Param names everywhere would add noise, not safety.
        'PSAvoidUsingPositionalParameters'

        # The tool is a single .ps1 SCRIPT, not a module: its functions are internal helpers, never
        # exported as cmdlets. Plural nouns (Get-IntakeQuestions, Get-ProblemDevices) read naturally
        # and are never surfaced to a user as commands.
        'PSUseSingularNouns'

        # Same single-file-script reasoning: internal helpers like Render-Html / Parse-BugCheckEvent
        # are never invoked as cmdlets, so an unapproved verb has no discoverability cost. Renaming
        # long-standing core functions in a trust-critical tool would be churn with real regression
        # risk and zero user benefit.
        'PSUseApprovedVerbs'

        # READ-ONLY is the product's whole trust position: no function changes machine state. The
        # New-*/Set-* helpers build in-memory objects or write the local report files - adding
        # -WhatIf/-Confirm would falsely imply a state-changing, abortable side effect on the machine.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        # Enforce the "target Windows PowerShell 5.1 - no PS7-only syntax (??, ?., ternary)" invariant
        # statically, as a second net under the dual-shell fixture gate. Flags syntax that would not
        # parse on 5.1 even when a given run never hits that code path.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        # The same invariant one level deeper: every COMMAND and PARAMETER used must exist on BOTH
        # Windows PowerShell 5.1 and PowerShell 7. Catches what the syntax rule cannot see - usage
        # that parses fine on 5.1 but fails at runtime (e.g. `ConvertFrom-Json -AsHashtable` is a
        # 7-only parameter) and cmdlets removed from 7 (e.g. Get-WmiObject). Profiles = the newest
        # Windows-CLIENT profiles PSScriptAnalyzer ships (Win10 1809 / 5.1 and Win10 1903 / 7.0).
        # The tool targets Windows 11, so a command valid only on a build NEWER than the profile
        # would false-positive - accepted tradeoff: the gate fails loud and a genuine case can be
        # suppressed with a comment here.
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
        }

        # And the same for .NET TYPES and their members (e.g. the core-only
        # System.Management.Automation.SemanticVersion would flag against the 5.1 profile).
        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
        }
    }
}
