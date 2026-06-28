# Second Opinion — design

## The one-line thesis
No incumbent does **cross-signal correlation + honest, confidence-tiered ranking + a portable
helper handoff** in one read-only pass. That integration is the whole moat; no single check is.

## Pipeline (three layers, deterministic-first)
```
Collect (read-only)  ->  Score/Rank (deterministic rules)  ->  Narrate (optional, AI, OUT of the binary)
```
- **Collect** — read-only PowerShell/CIM. Easy tier only in v0 (no admin, fast, low false-positive).
- **Score/Rank** — deterministic rules assign tier + confidence. *The LLM never assigns tiers.*
- **Narrate** — v0 has NO AI in the binary. We emit a redacted prompt; the human pastes it into
  their own ChatGPT/Claude. Keeps it free, private, offline-capable, model-agnostic.

## The unit of analysis is the COLLECTION, not one crash
Experts diagnose by *consistency across crashes*: same bugcheck/module every time → software/driver;
a different code every time → leans hardware. So the scorer reasons over the set of recent crashes
and computes bugcheck variance as a first-class signal. A single dump = "preliminary lead" at most.

## Hard guardrails (the safety mechanism, not polish)
These are what keep us from sending a friend to RMA good hardware:
1. `ntoskrnl.exe` / `ntkrnlmp.exe` attribution → auto-demote to "inconclusive" (kernel is usually
   the messenger for a third-party driver). Parse the stack, never WinDbg's "Probably caused by".
   *v0 status: **INERT.** v0 does no minidump module attribution — `Get-CrashEvents` reads the stop
   code + dump path only and the scorer never names a faulting module for a system crash, so there is
   nothing for this rule to demote yet. It activates when deep/minidump mode lands. (Takeover audit F2.)*
2. Kernel-Power 41 with `BugcheckCode == 0` and no matching dump → **checklist node, not a verdict**.
3. Require **>= 2 corroborating crashes** before any *hardware* claim; otherwise cap at Low.
   - **Documented exceptions** (a single event IS sufficient because it's a hardware *fact*, not a
     crash inference): a `0x124`/WHEA_UNCORRECTABLE or a fatal WHEA-Logger event (18/20/46) → Hardware
     High; a drive `HealthStatus` of Warning/Unhealthy → Drive High; a Windows Memory Diagnostic failure
     → Memory High. The whea-fatal, memdiag-zero-crash, and multi-bad-drive fixtures assert these.
   - **GPU High needs >= 2 INDEPENDENT channels** (Slice 6): the GPU rule counts distinct evidence
     channels — TDR (4101), GPU bugcheck (`0x116/7/9`), vendor driver event (153/14), Display
     problem-device — and reaches High only with >= 2 of them, OR a TDR flood (>= 5), OR a recurring GPU
     bugcheck (>= 2 crashes). A LONE channel (one bugcheck, or one flagged Display device) stays tier 2 —
     the lone-0x116 and lone-display-device fixtures assert this. (Same-cluster signals corroborate but
     are not fully independent; the explicit channel count makes that auditable, and
     replaced the old additive `$gpuSig` as the confidence driver.)
   - **GPU HARDWARE vs GPU driver (the `gpuhw` node).** The graphics card *itself* is a SEPARATE,
     secondary suspect from its driver. It fires ALONGSIDE (never supersedes) the driver node on
     corroborated GPU instability — `>= 2` independent channels OR a recurring GPU bugcheck (`>= 2`
     crashes) — and is capped at **tier 2 / "possible" (Medium)**: v0 reads only the stop code and
     CANNOT prove a failing card from a bad driver (every GPU signal is driver-or-hardware), so the
     confident "your GPU is dying" is withheld and the confirm path is the non-destructive swap-test
     ("rule out the driver with DDU first; do NOT RMA on this report alone"). A lone TDR, a single-channel
     TDR flood, a lone bugcheck, a lone Display device, or an unreadable GPU signal does NOT raise it.
     **INERT High path (deep-mode only):** a genuine GPU hardware FACT — a fatal WHEA attributed to the
     GPU/PCIe — would lift this node to tier 1 / High, but v0's WHEA collector does not attribute WHEA to
     a component (that payload parse is deep-mode), so the High path is inert in v0, exactly like the
     `ntoskrnl -> inconclusive` rule above.
   - Tier reflects confidence: **tier 1 == High**; Medium/Low inference-based culprits are tier 2
     ("possible"), never "prime suspect" off a lone signal.
4. Blank SMART data → say "not exposed for this drive", **never** render absent data as "healthy".
5. When signals are thin/conflicting → abstain: "insufficient evidence — capture this next".
6. **Evidence-quality accounting** (Slice B, completed in Slice 5): absence of data must NEVER read as a
   clean bill. EVERY collector reports whether its signal was actually *readable* — `Get-EventSignal`
   separates "query ran, 0 matches" (readable) from "query failed / access denied" (unreadable). For the
   main signals a "ruled out / clean" line is emitted ONLY when the signal was readable AND clean; an
   unreadable one becomes a neutral "could not be read — NOT checked" note. For the *culprit-only* event
   signals (TDR / GPU-vendor / storage / dump-failures / app-crashes / mem-diag) a failed read is a missed
   culprit (false-negative), not a false-clean, so it surfaces as one consolidated "may be UNDER-reported"
   note and never enters "ruled out". The green "came back clean" banner shows ONLY when `AllReadable` —
   every signal, main and culprit-only, was readable. `collection-failed` + `culprit-signals-unreadable`
   assert no false-clean ever escapes.

## Culprit node schema
`{ title, tierClass, tier, confidence, evidenceFor[], evidenceAgainst[], confirmBy, search }`
- tier: 1 (prime suspect) / 2 (possible) / checklist / ruled-out
- confidence: High / Medium / Low / Insufficient (rises with # independent corroborating signals)

## Optional intake (deterministic; informs the narrative, never the ranking)
A short fixed-choice questionnaire (`Get-IntakeAnswers`, gated behind `-NoIntake`, auto-skips any
non-interactive run so it can never block a piped/Quick-Assist/CI pass) captures the context only the
human knows: whole-PC-reboot vs app-close vs freeze, when it crashes, frequency, what was already tried
(clean install / DDU / reseat / part-swap), and OC/undervolt state. Stored as integer codes only — no
new PII. The scorer consumes it deterministically, but under a hard rule: **intake NEVER changes a tier
or confidence.** It only adds evidence lines / notes and retargets confirm steps (e.g. a done clean-
install/DDU adds a "software effectively ruled out → points at hardware" against-line and replaces the
GPU node's DDU step with a swap-test; an active manual-OC/undervolt raises an "uncontrolled variable"
note). The measured signals keep driving the order; self-reported symptoms enrich the explanation and
the AI's framing (surfaced as a report card + a `=== USER-REPORTED SYMPTOMS ===` block atop the prompt,
flagged ground-truth). This keeps every guardrail structurally intact — a user's report can't promote a
thin signal to a hardware verdict.

## Optional performance smoke test (opt-in; stability-adjacent, NEVER an "optimizer")
A `-PerformanceSmokeTest` switch (default OFF) runs one extra read-only collector (`Get-PerformanceSignals`)
that reads two existing System-log signals correlated with instability + poor performance: **CPU/firmware
throttling** (`Kernel-Processor-Power` Event 37 — the DESIGN-sanctioned *indirect thermal/power proxy*, the
read-only stand-in for the declined kernel temp driver) and **memory pressure** (`Resource-Exhaustion-Detector`
Event 2004, low-virtual-memory; count only). Like the corroborators, these are **evidence-only**: a throttle
signal adds a `For` line to an already-ranked hardware/power node (`cpu`/`power`/`handoff`) at any count, or
becomes an `Observed` weak signal once it clusters (`>= 5`); low-memory events are always `Observed`. **They
never create a culprit and never change a tier or confidence.** It is stability-adjacent diagnostics, NOT a PC
optimizer: every output is an observation + the cheapest reversible diagnostic step (watch temps / check
cooling / investigate memory use), never a tuning action (no startup/service/registry/pagefile/power-plan
changes, no benchmark or synthetic load). Honest abstention is load-bearing here: when the test runs it ALWAYS
emits a caveat note that a clean scan is **NOT a clean bill of health and NOT a temperature check** (it cannot
rule out overheating or a marginal PSU); an unreadable read is "NOT checked, not clean" (suppresses the clean
banner), never "good". Opt-in + golden-neutral: the switch-OFF path is byte-identical (every perf path is gated
on `$perfRequested`).

## Optional read-only transparency (`-WhatItReads`)
A `-WhatItReads` switch (default OFF) prints a categorized manifest of EVERY source the tool reads - the
System/Application event-log signals, the `Win32_*` CIM inventory classes, the storage/device cmdlets
(`Get-PhysicalDisk` / `Get-StorageReliabilityCounter` / `Get-Volume` / `Get-PnpDevice`), the read-only
`CrashControl` registry key, the bundled bugcheck KB, and the switch-gated reads (dump files only with
`-DeepDump`; CPU-throttle / low-memory only with `-PerformanceSmokeTest`) - then EXITS without collecting,
scoring, or writing anything. It is the honest answer to "what does this touch before I trust it?" for a
cautious first-time user or a friend over Quick Assist, and it reinforces the read-only trust position by making
the full read surface auditable up front. The manifest is a curated list (`Get-SoReadManifest`) kept honest by a
harness drift-guard that cross-checks the `Win32_*` classes the collectors actually query and asserts every
major read surface + switch-gated read is named, so it cannot silently drift from the code.

## Deliberately OUT of v0 (swamps that look easy)
- **Native CPU/GPU temps** — no reliable native API; the real path is a signed kernel driver,
  which breaks the read-only promise. Use indirect signals (WHEA events, KP41 clustering, and the opt-in
  `-PerformanceSmokeTest`'s `Kernel-Processor-Power 37` firmware-throttle proxy) instead.
- **Real minidump `!analyze`** — needs WinDbg + symbol downloads. Optional "deep mode" later.
  v0 reports the bugcheck *code + name* from events only; it does not claim the faulting driver.
- **Deep per-attribute SMART** — needs elevation / bundled smartctl. v0 uses HealthStatus + Wear%.
- Any GUI, any code-signing, any AI API call.

## Known v0 shortcuts (tech debt, tracked)
- Correlation rules are functions in the script, NOT data-driven from `data/rules.json` — and a Slice 6
  design workflow (3 adversarially-vetted schema proposals) DECLINED to migrate them: a rules engine is
  the inner-platform anti-pattern here (it would relocate only the ~6 trivial rules into a JSON DSL while
  every load-bearing rule + all guardrails stay in code, adding interpreter/DSL/lint as trust surface for
  a marginal editability win). The editable-KB moat is served by `data/bugchecks.json` (consumed via
  `Get-BugcheckInfo`); the rule functions stay legible PowerShell. **Revisit trigger:** the rule set grows
  several-fold OR untrusted third parties author rules.
- `data/bugchecks.json` = 63 stop codes (keyed object; name/class/hint/search), the one consumed data KB.
- **Event vocabulary is code, not data (single source of truth).** Which events the scorer acts on lives
  in the collectors (e.g. WHEA fatal IDs 18/20/46, TDR 4101, vendor 153/14, volmgr 161). An earlier
  event-vocabulary data file was removed because it was loaded but never read and had drifted from the
  code, so the same IDs lived in two places and disagreed. When `rules.json` lands, the event
  vocab gets consumed there as part of a coherent schema — not bolted onto the logic-heavy collectors.

## Compatibility
Target **Windows PowerShell 5.1** (ships on every Win11). No PS7-only syntax (`??`, `?.`, ternary).
Test under both `powershell.exe` (5.1) and `pwsh` (7).
- **`Sort-Object` is NOT a stable sort on 5.1** (it is on 7). The culprit sort therefore ends on a
  stable insertion-index tiebreaker so equally-ranked cards order identically on both versions — keep
  it, or two checklist cards can silently swap order between 5.1 and 7. The dual-version gate caught
  exactly this; a PS7-only gate would have shipped the divergence.

## Positioning vs the field
- vs Microsoft "PC Health Check" app: name collision avoided; that's an upgrade checker, not a triager.
- vs Microsoft's 2026 crash-recovery push — the Windows Resiliency Initiative, Quick Machine Recovery,
  Driver Quality Initiative, and Cloud-Initiated Driver Recovery (faulty-driver rollback via Windows
  Update; rolling out 2026) — the clock we race (there is no MS product literally branded "Predictive
  Health"). It makes basic recovery + driver remediation less exotic, but it auto-acts on the machine
  and targets the common case: we are read-only (vs their auto-apply / auto-rollback), portable/no-install,
  work on old/un-updated/offline boxes, AI-optional, third-party-helper — owning the ambiguous
  real-world PC they are NOT targeting.
- vs WhoCrashed / mcp-windbg / CrystalDiskInfo: all single-signal. We fuse + rank + abstain honestly.
