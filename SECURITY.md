# Security & privacy

Second Opinion is a read-only local diagnostic. It makes no changes to the machine and never sends data
anywhere — the AI step is you pasting a prompt into your own AI.

## Reporting

**Please do not paste an unredacted report, or any identifier that survived into `ai-prompt.txt`, into a
public issue** — that would leak exactly what this tool is trying to protect.

- **Privately (preferred for anything sensitive):** use GitHub's **private vulnerability reporting** on this
  repo (the **Security** tab → *Report a vulnerability*). It opens a private channel with the maintainer.
- **Redaction gaps (the most valuable report):** `ai-prompt.txt` has key identifiers (username, PC name,
  BIOS serial, MAC / IP) removed on a best-effort basis — it is *not* guaranteed. If you find an identifier
  that survives into `ai-prompt.txt`, report it **privately**, and describe it in sanitized form (don't
  include the real value).
- **Ordinary bugs (no sensitive data):** a regular GitHub issue is fine.

## Artifact safety

- `report.html` is **unredacted** (it shows the PC name and hardware). Share it only with the person helping
  you, never publicly.
- `ai-prompt.txt` is the share-safe artifact (best-effort redacted). There is no redacted HTML report yet.
- The tool never writes outside the output folder you choose (default `.\out`) and never touches Windows
  settings, the registry, services, or drivers.
