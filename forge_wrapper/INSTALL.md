# Stage A host setup — review only

Source and unit examples only. The install owner controls credential
provisioning, activation, Core binding and the first live read. Do not enable
the binding until the protected transport and isolated probes pass.

## Install inputs

- Use a dedicated non-login service account, `forge-wrapper`. Run it as
  non-root. The reviewed source under `/opt/forge-wrapper` is root-owned and
  writable by neither the service nor Core. Use patched Linux, Git and
  Python 3.11 or later.
- Find the host UID of both trusted Core web and job processes. Both roles
  must connect as that UID; check any container user namespace mapping.
  Give only those processes access through the `forge-core` group. Core
  must also see the systemd listener's UID as 0. Never mount the socket in
  an agent computer.
- The socket must be root-owned and mode 0660 (0600 for root-only Core).
  Its ancestors must be root-owned directories, not symlinks, and not
  group- or other-writable. Mount only the socket's parent into Core, read-only.
  Root systemd creates and listens on the socket. The wrapper expects
  activation for its own PID and exactly one descriptor (fd 3); it does not
  bind a socket itself. It checks the inherited descriptor is a listening
  pathname AF_UNIX stream with a root kernel peer, then checks ownership of
  the socket and its path.
- Set `--agent-id` and `--workspace-id` to the install's two positive
  decimal IDs (up to 2^63−1, no sign or leading zero). Set `--core-uid`
  to the verified host UID. These are required and have no defaults.
- Set `--origin` to the install's HTTPS origin: a lowercase hostname with
  optional port, no path, trailing slash, query, fragment or userinfo.
  Redirects and inherited HTTP proxies are disabled; keep TLS verification on.
- Set `--repos-file` to an absolute path to a root-owned regular JSON file,
  readable by the service and not writable by its group or others. Symlinks
  and untrusted ancestors are refused. The contents are a single array
  (max 16 KiB), for example `["fixture-org/project"]` (synthetic). Each
  entry is a literal `owner/repo` up to 160 ASCII bytes; each part starts
  with a letter or digit and may then contain letters, digits, underscores
  and hyphens. Invalid or duplicate entries prevent startup. `[]` starts
  with access to nothing. The list is loaded once at startup and is the same
  object used for request validation and both upstream transports. A Core
  prefilter must not be broader than this install's list.
- The install owner provisions a read-only forge identity restricted to the
  approved repositories. Place the token in a regular single-link file with
  mode 0600, owned by the service account. Format: one ASCII
  `BOT_LOGIN:PAT` line. Keep it out of arguments, environment, unit files
  and logs. The wrapper checks the opened file without following symlinks.
- Pre-create the scratch directory owned by the service account, mode 0700,
  on a filesystem with a space limit. The wrapper uses temporary bare Git
  repositories there. There is no write receipt or push audit.

## Example units for review

`forge-wrapper.socket`:

```ini
[Unit]
Description=Protected Core forge socket

[Socket]
ListenStream=/run/forge-wrapper/forge.sock
Accept=no
SocketUser=root
SocketGroup=forge-core
SocketMode=0660
DirectoryMode=0755
RemoveOnStop=yes

[Install]
WantedBy=sockets.target
```

`forge-wrapper.service` (substitute the verified IDs and origin):

```ini
[Unit]
Description=Read-only forge wrapper
Requires=forge-wrapper.socket
After=forge-wrapper.socket network.target

[Service]
Type=exec
User=forge-wrapper
Group=forge-wrapper
ExecStart=/opt/forge-wrapper/bin/forge-wrapper --core-uid CORE_UID --agent-id AGENT_ID --workspace-id WORKSPACE_ID --origin https://forge.example.invalid --repos-file /etc/forge-wrapper/repos.json --token-file /etc/forge-wrapper/token --scratch /var/lib/forge-wrapper/scratch
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadWritePaths=/var/lib/forge-wrapper/scratch
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=
LimitCORE=0
```

## Checks before any live use

1. With synthetic config and an isolated fixture, verify a well-formed
   `pr` on an unlisted repo and the same read against `[]` both return
   `refused/repo`, with no upstream traffic. The offline tests exercise all
   four verbs and verify that these denials precede token reads.
2. Inspect socket and ancestor type, mode and owner with `stat`. Verify the
   socket unit is listening and the service runs as the configured non-root
   account. Check token metadata only; never print the token.
3. Exercise the protected transport from Core's web/job credential context.
   Core must `lstat` the socket and its ancestors, connect once, then check
   Linux `SO_PEERCRED` for UID 0 **before writing any request bytes**.
   A correctly owned path is not a substitute for the peer check. The
   wrapper separately verifies Core's UID before reading. A wrong agent
   or workspace must return `refused/agent` without touching upstream.
4. If separately approved, read a known PR in an allowed repository.
   Record the response status, repository, PR number and head SHA only.
   If any check fails, leave the Core binding off. Do not retry automatically.
