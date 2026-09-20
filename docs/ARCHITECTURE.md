# Implementation notes

## Flow

```text
User starts diagnosis and opens LoL
  → incremental logs + system TCP + optional Mihomo connections
  → observations, timestamps and user stage markers
  → report: findings / progress / uncertainty / next actions
  → optional target confirmation and unauthenticated probes
  → route preview → apply → observe new game connections → restore
```

## Components

| File | Responsibility |
|---|---|
| `lol-guide.ps1` | Beginner workflow, stage markers and report UI |
| `lol-session.ps1` | Incremental logs, connection observations, session reports and summary export |
| `lol-route-lab.ps1`, `lol-ui-tools.ps1` | Advanced node/target management, cached test results and routing controls |
| `lol-worker.ps1` | Serialized background actions, testing and routing orchestration |
| `lol-data.ps1` | Local storage, validation and credential protection |
| `lol-probe.py` | Unauthenticated TLS/HTTP/configuration probes |
| `lol-core.ps1`, `lol-routing-review.ps1` | Mihomo control, rule state and actual-route comparison |
| `LolConnectLauncher.cs` | Small Windows GUI launcher |

Session reports distinguish event timestamps from observation times. Existing logs are initially checkpointed at EOF. Observations persist extracted fields instead of raw log lines. Known destination matches can suggest a group; unknown targets require confirmation.

Routing proof requires a recognizable game process and, after applying changes, a sufficiently recent connection start. Missing observations remain unverified. Saved routing context is checked against network, source configuration, rules and targets; old results are not automatically evidence of the current route.

## Run checks

From the repository root in PowerShell 7:

```powershell
./test-lol-session.ps1
./test-lol-routes.ps1
./test-lol-lab.ps1
python -m unittest discover -p test_lol_probe.py
./test-lol-core-isolated.ps1 -CorePath 'C:\path\to\mihomo.exe'
./Build-Launcher.ps1
```

The TLS integration fixtures additionally use `cryptography`; without it those three tests are explicitly skipped. The independent core test does not enable TUN or system proxy. Tests use isolated data directories. These tests do not launch a real game or validate every ISP/region.

## Data boundaries

User data defaults to `%LOCALAPPDATA%\LolRouteLab`; `LOL_LAB_DATA` can select an isolated development directory. Node passwords use Windows current-user DPAPI. Configuration backups may contain subscription credentials and must not be published. Exported summaries exclude raw logs, local paths, node definitions and routing chains. No automated telemetry or log upload is implemented.

## Known constraints

- Best-effort parsing of accessible UTF-8/UTF-16 logs; client changes and protected processes may reduce visibility.
- Template endpoints are not a complete official service catalog.
- Routing matches addresses/ports and cannot isolate authentication from public traffic on the same service.
- Existing Clash rules remain active; the tool does not guarantee that unrelated traffic goes direct.
- A Windows installation of PowerShell 7 is required; this is not a bundled-runtime installer.
- Real game acceptance remains separate from synthetic and integration tests.
