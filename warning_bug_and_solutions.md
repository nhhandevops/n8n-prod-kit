# warning_bug_and_solutions.md — n8n Production Kit

Format per entry: symptom → root cause → how to verify → fix → date.

## 2026-10-07 · hadolint install script failed: "release assets not found"

- **Symptom:** `install-devtools.sh` aborted at the hadolint step after apt + gh had already installed.
- **Root cause:** the script expected a per-asset `hadolint-Linux-x86_64.sha256` file. Since v2.15.x the release ships one `checksums.sha256` and lowercase asset names (`hadolint-linux-x86_64`).
- **Verify:** `curl -fsSL https://api.github.com/repos/hadolint/hadolint/releases/latest | jq -r '.assets[].name'`.
- **Fix:** download `checksums.sha256`, take the line whose last field is `hadolint-linux-x86_64`, compare with `sha256sum`. Same pattern belongs in `scripts/bootstrap-host.sh` / CI when hadolint is pinned there: pin the version + sha256 in the script instead of resolving "latest" at run time.

## 2026-10-07 · VMware: VM shows as powered off but a `.vmem.lck` lock directory exists

- **Symptom:** `vmrun list` → 0 running VMs, yet `D:\vms\server1\server1-<id>.vmem.lck\` is present (dated weeks earlier).
- **Root cause:** stale lock from an unclean host shutdown; only `vmware-tray.exe` was running.
- **Verify:** `Get-Process vmware, vmware-vmx` → none; lock directory timestamp old.
- **Fix:** nothing to delete — VMware clears it on next power-on (choose "Take Ownership" if prompted). Edit `.vmx` only while no `vmware-vmx.exe` runs; keep a backup copy of the `.vmx` first.

## 2026-10-07 · Build plan drafted for the wrong machine

- **Symptom:** build plan §2/§6 assumed an MSI desktop with WSL2 (user `nguye`, 32 GB, `D:\Hobbies\…`); the machine in use is a laptop (16 GB, Windows 10, no WSL distro) whose only Linux is the VMware VM `server1` (Ubuntu 26.04).
- **Root cause:** the plan was written from a different session/host without re-checking the environment.
- **Verify:** `Get-CimInstance Win32_ComputerSystem`; `wsl -l -v`; `vmrun list`; `%APPDATA%\VMware\inventory.vmls`.
- **Fix:** §2/§5/§6/§17/§18 of the build plan rewritten for the VM (ports 8080/8443, Remote-SSH, Ubuntu 26.04 in the bootstrap/CI matrix); HANDOFF §3/§4/§7 updated. Rule going forward: start every machine-setup session with the read-only host/VM inventory block before editing plans.

## 2026-10-07 · Shared VM: ports 80/443 and disk nearly full

- **Symptom:** `ss -ltnp` on `server1` shows host nginx on :80 and nginx-proxy-manager on :443/:81; root disk 81 % used (15 GB free), `docker system df` → 13 GB build cache with 0 active entries.
- **Root cause:** the VM hosts five other compose projects; months of builds left cache behind.
- **Verify:** `docker system df`; `docker builder du`; `df -h /`.
- **Fix:** `docker builder prune -af` + `docker image prune -af` (→ 32 GB free; running projects untouched); kit runs on `HTTP_PORT=8080 HTTPS_PORT=8443`; `make preflight` must name the PID holding a port (TC-002) — this VM is a natural test for it.
