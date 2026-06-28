# Security & privacy

Second Opinion is a read-only local diagnostic. It makes no changes to the machine and never sends data
anywhere — the AI step is you pasting a prompt into your own AI.

## Reporting

**Please do not paste an unredacted report, or any identifier that survived into `ai-prompt.txt`, into a
public issue** — that would leak exactly what this tool is trying to protect.

- **Privately (preferred for anything sensitive):** use GitHub's **private vulnerability reporting** on this
  repo (the **Security** tab → *Report a vulnerability*). It opens a private channel with the maintainer.
- **Redaction gaps (the most valuable report):** `ai-prompt.txt` has key identifiers removed on a best-effort
  basis — username, PC name, BIOS serial, network addresses, Windows profile path names, and raw device display
  names that may carry personal labels — but it is *not* guaranteed. If you find an identifier that survives
  into `ai-prompt.txt`, report it **privately**, and describe it in sanitized form (don't include the real value).
- **Ordinary bugs (no sensitive data):** a regular GitHub issue is fine.

## Artifact safety

- `report.html` is **unredacted** (it shows the PC name and hardware). Share it only with the person helping
  you, never publicly — not on a forum, in a chat, or as a screenshot.
- **Share-safe artifacts** (best-effort redacted): `ai-prompt.txt`, and the `out\packet\` files from
  `-HelperPacket` (`helper-summary.md`, `redacted-evidence.json`, `redaction-audit.txt`,
  `unreadable-signals.txt`). Use these for public help / AI / forums. There is no redacted HTML report yet.
- **Don't post publicly:** `report.html`, the whole `out` folder, or screenshots of `report.html`.
- The tool never writes outside the output folder you choose (default `.\out`) and never touches Windows
  settings, the registry, services, or drivers.
