# Contributing

Thanks for looking. Second Opinion is one read-only PowerShell tool with a deterministic scorer and a
fixture harness — the whole thing is a single script plus tests.

## The shape of it

```
src/Invoke-SecondOpinion.ps1
  collectors (read-only)  ->  New-Diagnosis (deterministic scorer)  ->  Render-Html  ->  Build-AiPrompt  ->  redaction
```

- **Collectors** are `Get-*` / CIM / Event-Log queries. Every one is read-only — that is the product's whole
  trust position; a change that mutates the machine or adds a network call won't be accepted.
- **`New-Diagnosis`** is the deterministic scorer: rules emit ranked "culprit" objects with a tier and a
  confidence. The AI never ranks — it only narrates the deterministic output.
- **`Render-Html`** writes the (unredacted) `report.html`; **`Build-AiPrompt`** writes the redacted
  `ai-prompt.txt`.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the rationale and the safety guardrails (honest abstention,
"absence is not a clean bill," GPU needs >= 2 independent evidence channels, and so on).

## Invariants (don't break these)

- **Read-only.** No cmdlet that changes the machine; no network.
- **The deterministic scorer assigns tiers/confidence — the AI never ranks.**
- **Honest abstention over a confident guess.** Absence / unreadable data must never render as "clean."
- **Target Windows PowerShell 5.1** (no PS7-only syntax) and keep the source ASCII-only.

## The test gate

Any scorer change must keep the harness green on **both** Windows PowerShell 5.1 and PowerShell 7:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Fixtures.ps1
pwsh -File .\tests\Run-Fixtures.ps1
```

- **Snapshots** (`tests/golden/*.expected.txt`) pin each fixture's full output; regenerate them intentionally
  with `-Update` and review the diff.
- **Guardrail assertions** must always hold regardless of snapshots — a *violated* assertion fails the suite;
  fix the cause, don't `-Update` past it.

## Adding a signal or a rule

1. Add a read-only collector (or extend one) — keep it a `Get-*` / CIM query.
2. Thread it into `New-Diagnosis` as a new rule or evidence line.
3. Add a fixture in `tests/Fixtures.ps1` plus a guardrail assertion in `tests/Run-Fixtures.ps1` that pins the
   behavior you intend — especially any abstention boundary.
4. Run the gate on 5.1 + 7, `-Update` the golden deliberately, review the diff, open a PR.

Keep changes small and evidence-backed. The goal is a tool a stranger can trust not to send their friend to
RMA good hardware.
