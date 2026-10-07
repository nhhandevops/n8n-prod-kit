# RHEL-family hosts (Rocky, AlmaLinux, CentOS Stream, Oracle Linux, RHEL 9/10)

The kit runs unchanged on the Enterprise Linux family. `scripts/bootstrap-host.sh` prepares such a host; this page explains what it does differently from Ubuntu/Debian and what to check afterwards.

## What bootstrap-host.sh does on EL

| Step | EL specifics |
|---|---|
| Docker repository | Copies `https://download.docker.com/linux/centos/docker-ce.repo` into `/etc/yum.repos.d/` — no `dnf config-manager` plugin needed. The CentOS repo serves identical packages for Rocky, Alma, Oracle and RHEL 9/10 (verified: docker-ce 29.8.2, compose 5.6.0 on all of them). |
| Packages | `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin make jq git`. **`curl` is deliberately not listed on EL9**: those images ship `curl-minimal`, and asking for `curl` aborts the whole transaction; `/usr/bin/curl` already exists. |
| `dnf` version | All EL10 releases (Rocky/Alma/CentOS Stream/RHEL/Oracle 10.2) still ship dnf 4.20, so the `dnf config-manager addrepo` syntax from the Fedora docs does not apply. |
| firewalld | If `firewalld` is installed **and** active: `firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload`. The container test matrix cannot exercise this (no D-Bus); it is verified on a real host. |
| SELinux | Left **enforcing**. Every bind mount in the kit carries the `:z` flag (`./caddy:/etc/caddy:ro,z`), which relabels the host directory for container access; named volumes need nothing. |
| Kernel | `vm.overcommit_memory=1` (Valkey/Redis requirement), persisted in `/etc/sysctl.d/90-n8nkit.conf`. |
| Docker group | The invoking user (`$SUDO_USER`, not `$USER`, which is root under `sudo`) is added to `docker`; log out and in once. |

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash
# or: git clone … && sudo scripts/bootstrap-host.sh [--yes] [--no-start] [--no-group]
```

## After bootstrap

```bash
getenforce                      # Enforcing is fine
sudo firewall-cmd --list-services   # must include http https (when firewalld is active)
docker --version && docker compose version
cd n8n-prod-kit/compose && make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com && make preflight && make up
make doctor                     # reports SELinux mode and the firewalld services
```

## Known differences and gotchas

- **Library container images are stale or missing** for Rocky: `rockylinux:9` on Docker Hub is a 2023 build and `rockylinux:10` does not exist. The kit's test matrix uses `quay.io/rockylinux/rockylinux:9|10` and `public.ecr.aws/docker/library/almalinux:9` (same digests as Hub, no pull quota).
- **`ID_LIKE` is not a reliable family key**: Oracle Linux and RHEL set only `fedora`. The script matches `ID` (rhel, centos, rocky, almalinux, ol) or `PLATFORM_ID=platform:el9|el10`.
- **EPEL** (only needed for dev tools such as `age` and ShellCheck, never for running the kit): `dnf install epel-release` on Rocky/Alma/CentOS Stream 9 and 10; on RHEL proper install the EPEL rpm by URL.
- **Verified so far**: the install path in containers for Rocky 9/10 and Alma 9 (weekly `bootstrap-matrix` workflow). A full run on a real EL host with SELinux enforcing and firewalld active is tracked in `n8n-kit-HANDOFF.md` §7 — treat EL support as "install path verified, host firewall path pending" until that box is ticked.
