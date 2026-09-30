<!-- Author: Lei Zhao <lei1.zhao@sk.com> -->

# solab-tools

Solab server setup and maintenance scripts. See [`SERVERS.md`](SERVERS.md) for
server details.

## New-server setup order

Run applicable numbered scripts in order as your normal user. Scripts request
sudo authentication when needed.

| Script | Purpose |
| --- | --- |
| `01-install-ca-to-fix-https-download-errors.sh` | Install the CA chain needed for HTTPS downloads through lab TLS inspection. See [`certs/README.md`](certs/README.md). |
| `02-install-github-date-time-service.sh` | Install and enable the fallback clock service. |
| `03-fix-ubuntu-apt-sources.sh` | Repair Ubuntu APT sources and network timeouts. |
| `04-add-regular-users-to-shared-group.sh` | Add regular users to `shared`. |
| `05-setup-s1-shared-storage.sh` | Mount the s1 models and datasets shares through `192.168.3.61`.<br>PS: Run this only on client servers because s1 hosts the storage locally. |
| `06-grant-docker-access-to-regular-users.sh` | Add regular users to `docker`.<br>PS: Docker group membership grants root-equivalent access and requires `--grant-root-equivalent-access`. |
| `07-install-node-npm-global.sh` | Install Node.js and npm globally for all users. |
| `08-install-kilocode-cli-global.sh` | Install the latest Kilo CLI globally for all users. |
| `09-install-opencode-global.sh` | Install the latest OpenCode CLI globally for all users. |
| `10-setup-user-opencode-kilocode.sh` | Configure the current user's OpenCode and Kilo clients for the X3 Qwen service.<br>PS: Each user should run this script once in their own login session. |
| `11-create-solab-user-like-labuser.sh` | Create an optional local user with the same supplementary groups as `labuser`.<br>PS: Only `labuser` may run this script. |

Apply-mode evidence is stored under `~/.local/state/solab-tools`; scripts
refuse to write run logs inside the Git checkout.

Maintenance tools are documented in [`maintenance/README.md`](maintenance/README.md).
