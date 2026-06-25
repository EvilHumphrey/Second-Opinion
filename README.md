# Second Opinion

A **read-only second opinion for a misbehaving Windows 11 PC.** It does one pass over the
signals that actually matter — crash/bugcheck history, unexpected-restart and hardware-error events,
drive health, app crashes, problem devices — fuses them into a **confidence-tiered list of likely culprits**,
and hands you two things:

1. `report.html` — a self-contained report for you or the person helping you. It is **not
   redacted** (it shows the PC name and hardware), so share it only with your helper, not publicly.
2. `ai-prompt.txt` — a context-stuffed prompt with the **key identifiers removed** (username, PC
   name, BIOS serial, MAC/IP — best-effort, not guaranteed), so it's the one safe to paste into
   ChatGPT / Claude.

It is built for the person doing the helping. The friend with the broken PC just runs it (or you
run it for them over Quick Assist) and sends back a file.

## What makes it different

- **It ranks, and it shows its work.** Every culprit comes with evidence *for*, evidence
  *against*, and the cheapest reversible step to confirm it.
- **It is honest when it doesn't know.** A restart with no recorded cause becomes a checklist,
  not a fake verdict. It abstains rather than guess on thin evidence.
- **It changes nothing.** No fixes, no "optimizing," no settings touched. Nothing to undo.

## What it is NOT

- Not an antivirus.
- Not a "PC optimizer" / one-click tune-up.
- It does **not** change Windows settings, the registry, services, or drivers — read-only by design.
  The only thing it writes is its two output files, into the folder you choose (default `.\out`).
- It does not phone home. The AI step is *you* pasting a redacted prompt into your own AI.

## Usage

```powershell
# From the project folder, in Windows PowerShell:
powershell -ExecutionPolicy Bypass -File .\src\Invoke-SecondOpinion.ps1 -OpenReport
```

Options:
- `-Days <n>` — how far back to look (default 30).
- `-OutDir <path>` — where to write the report (default `.\out`).
- `-OpenReport` — open the HTML report when done.
- `-NoRedact` — leave the AI prompt un-redacted (off by default; redaction is on).

Some detailed signals (SSD wear, certain device problem codes) populate only when run
elevated. It runs fine without elevation and tells you what it couldn't read.

## Requirements

- Windows 10 or 11. Targets **Windows PowerShell 5.1** (ships with every Windows) and also runs on
  PowerShell 7+. Nothing to install.
- No administrator rights for the core run; a few detailed signals (SSD wear, some device problem
  codes) populate only when run elevated, and the report says what it couldn't read.

## What it collects

All read-only, all local — it reads (never writes) these and fuses them into the ranking:

- Crash / bugcheck history and unexpected-restart (Kernel-Power 41) events from the Event Log.
- Hardware-error (WHEA) events, display-driver timeout (TDR) events, and GPU vendor reset events.
- Physical-disk SMART / reliability counters, volume free space, and the crash-dump policy.
- Problem devices from Device Manager and application-crash events.
- Optionally, your answers to a short symptom questionnaire (stored as integer codes — no free text).

It does **not** read your documents, browsing history, or personal files, and it never sends anything
anywhere. `report.html` is unredacted (for your helper only); `ai-prompt.txt` has key identifiers
removed (best-effort) so it's the one safe to paste into an AI. There is no redacted HTML report yet —
for public sharing, use `ai-prompt.txt`.

## Reporting a problem

Found a bug — or an identifier that survives redaction in `ai-prompt.txt`? Please open an issue (see
[`SECURITY.md`](SECURITY.md)). Redaction is best-effort identifier removal, not a guarantee.

## License

MIT — see [`LICENSE`](LICENSE). Provided as-is, without warranty. See [`docs/DESIGN.md`](docs/DESIGN.md)
for the architecture and the abstention / guardrail safety model.

## Status

v0 — terminal-only, runnable.
