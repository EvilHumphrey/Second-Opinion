# Security & privacy

Second Opinion is a read-only local diagnostic. It makes no changes to the machine and never sends data
anywhere - the AI step is you pasting a prompt into your own AI.

## Reporting

- **Bugs / security issues:** please open a GitHub issue. If you would rather report privately, say so in
  the issue and a maintainer will follow up.
- **Redaction gaps (the most valuable report):** `ai-prompt.txt` has key identifiers (username, PC name,
  BIOS serial, MAC / IP) removed on a best-effort basis. It is *not* guaranteed. If you find an identifier
  that survives into `ai-prompt.txt`, please report it - that is exactly the kind of issue worth fixing.

## Artifact safety

- `report.html` is **unredacted** (it shows the PC name and hardware). Share it only with the person
  helping you, never publicly.
- `ai-prompt.txt` is the share-safe artifact (best-effort redacted). There is no redacted HTML report yet.
- The tool never writes outside the output folder you choose (default `.\out`) and never touches Windows
  settings, the registry, services, or drivers.
