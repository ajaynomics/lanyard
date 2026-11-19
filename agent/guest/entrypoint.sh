#!/bin/sh
# The entrypoint of an agent's Sprite (Dockerfile.agent), after an earlier
# browser desktop image's. POSIX sh supervisor for the screen, the spawner
# and the relay, each started as its own user with a fixed environment:
#
#   as agent: Xvfb :99 -> openbox -> x11vnc 127.0.0.1:5900 -> websockify
#     127.0.0.1:6080; spawner.mjs on /run/spawn/agent.sock, which starts the
#     pi-env daemon (and so the agent's shell) and command connectors.
#   as browser: cdp.mjs, which runs Chromium (profile in /home/browser, on
#     --remote-debugging-pipe) and serves its DevTools on 127.0.0.1:9222
#     only under a token made at each boot in /run/browser/cdp-token; and a
#     second spawner.mjs on /run/browser-spawn/browser.sock, which runs only the
#     screen's scripts (visit, fill, pay, answer, upload) for the relay (#60).
#   as root, once: the folder the browser shares with the agent,
#     /home/agent/browser-files (agent, group browser, 2770).
#   as desk:  server.js (the desktop control server, control-only) on
#     127.0.0.1:8090, with a bearer made at each boot in /run/desk/token.
#   as relay: sprite-relay.mjs on $PORT, with the relay's secret and the bearer.
#
# It starts as root only to do that, and then only watches: it reads nothing
# the agent writes. The agent can read neither the relay's secret nor the
# bearer: not in a file, not in its environment, not in another user's
# /proc/<pid>/environ. Every listener but the relay binds the guest's own
# loopback or a private socket. The agent cannot reach the screen's DevTools,
# so it cannot read what a filler types (#60). Chromium keeps its sandbox.
# Exits 1 as soon as a child dies (cdp.mjs starts Chromium again itself); the
# platform restarts the entrypoint. The platform does not apply the image's
# ENV, so everything is set here.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
GUEST=/opt/agent
AGENT_HOME=/home/agent
BROWSER_HOME=/home/browser
PROFILE="$BROWSER_HOME/.config/chromium"

# Without root, every process would share one user, and the agent could read
# the secrets; refuse rather than run so.
[ "$(id -u)" = 0 ] || { echo "entrypoint: must start as root, to start each process as its own user" >&2; exit 1; }

DISPLAY=:99 TZ="${TZ:-America/Los_Angeles}"
RELAY_SECRET="${SPRITE_RELAY_SECRET:-}"
RELAY_PORT="${PORT:-8080}"
SPAWN_SOCKET=/run/spawn/agent.sock
BROWSER_SOCKET=/run/browser-spawn/browser.sock
SCRIPTS=$GUEST/visit.mjs:$GUEST/fill.mjs:$GUEST/pay.mjs:$GUEST/answer.mjs:$GUEST/upload.mjs
# The one folder the browser and the agent share: its downloads (Chromium's
# policy, /etc/chromium/policies/managed/agent.json) and the files the agent
# uploads (agent/browser-upload.mjs).
SHARED="$AGENT_HOME/browser-files"
# Only root, which writes them, reads the logs: /tmp is the agent's to plant links in.
LOGDIR=/run/sprite-logs

# Each user's fixed environment; nothing of this process's own passes on.
# Each replaces the shell it runs in, so a spawned child's pid is the program's
# own; run one in the foreground in a subshell.
as_agent() {
  exec env -i PATH="$PATH" HOME="$AGENT_HOME" USER=agent LOGNAME=agent SHELL=/bin/sh DISPLAY="$DISPLAY" TZ="$TZ" \
    PI_TELEMETRY=0 SPRITE_SPAWN_SOCKET="$SPAWN_SOCKET" su-exec agent "$@"
}
# A secret never goes in an argument: any user can read a process's
# /proc/<pid>/cmdline, if only for a moment. Each is a file only its user
# reads, put into the environment by that user's own shell just before its
# program replaces it.
as_desk() {
  # shellcheck disable=SC2016 # expanded by the desk user's shell, not root's
  exec env -i PATH="$PATH" DISPLAY="$DISPLAY" TZ="$TZ" TMPDIR=/run/desk \
    PI_DESKTOP_SUPERVISE=0 PI_DESKTOP_HOST=127.0.0.1 PORT=8090 PI_DESKTOP_WIDTH=1280 PI_DESKTOP_HEIGHT=800 \
    su-exec desk sh -c 'PI_DESKTOP_TOKEN=$(cat /run/desk/token) && export PI_DESKTOP_TOKEN && exec "$@"' sh "$@"
}
# The screen's browser and its scripts, with DevTools' token (cdp.mjs).
as_browser() {
  # shellcheck disable=SC2016 # expanded by the browser user's shell, not root's
  exec env -i PATH="$PATH" HOME="$BROWSER_HOME" USER=browser LOGNAME=browser SHELL=/bin/sh DISPLAY="$DISPLAY" TZ="$TZ" \
    PI_DESKTOP_PROFILE_DIR="$PROFILE" SPRITE_SPAWN_SOCKET="$BROWSER_SOCKET" SPRITE_SPAWN_SCRIPTS="$SCRIPTS" \
    su-exec browser sh -c 'SPRITE_CDP_TOKEN=$(cat /run/browser/cdp-token) && export SPRITE_CDP_TOKEN && exec "$@"' sh "$@"
}
as_relay() {
  # shellcheck disable=SC2016 # expanded by the relay user's shell, not root's
  exec env -i PATH="$PATH" PORT="$RELAY_PORT" SPRITE_SPAWN_SOCKET="$SPAWN_SOCKET" SPRITE_BROWSER_SOCKET="$BROWSER_SOCKET" \
    su-exec relay sh -c 'SPRITE_RELAY_SECRET=$(cat /run/relay/secret) && PI_DESKTOP_TOKEN=$(cat /run/relay/desk-token) &&
      export SPRITE_RELAY_SECRET PI_DESKTOP_TOKEN && exec "$@"' sh "$@"
}

# Made afresh at each boot. /run/spawn: the agent's spawner listens there, and
# only the relay may connect. /run/desk: the bearer, the desktop server's alone.
# /run/browser: DevTools' token, the browser user's alone; /run/browser-spawn:
# its spawner, which only the relay may reach.
rm -rf "$LOGDIR" /run/spawn /run/desk /run/relay /run/browser /run/browser-spawn
mkdir -m 700 "$LOGDIR"
mkdir -m 750 /run/spawn && chown agent:relay /run/spawn
mkdir -m 750 /run/browser-spawn && chown browser:relay /run/browser-spawn
mkdir -m 700 /run/browser && chown browser:browser /run/browser
mkdir -m 700 /run/desk && chown desk:desk /run/desk
mkdir -m 700 /run/relay && chown relay:relay /run/relay
umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /run/desk/token
cp /run/desk/token /run/relay/desk-token
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /run/browser/cdp-token
chown browser:browser /run/browser/cdp-token
printf '%s' "$RELAY_SECRET" > /run/relay/secret
chown desk:desk /run/desk/token
chown relay:relay /run/relay/desk-token /run/relay/secret
umask 022
(as_browser mkdir -p "$PROFILE")
# The shared folder: the agent's, group browser, set-group-ID so what either
# puts there stays the group's (2770). The agent can write its home, and so
# could leave a link here to a file of root's; root changes it only through
# a handle opened on the folder itself, which follows no link.
(as_agent mkdir -p "$SHARED") || true
node -e 'const fs = require("fs"); const [path, uid, gid] = process.argv.slice(1);
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  fs.fchownSync(fd, Number(uid), Number(gid)); fs.fchmodSync(fd, 0o2770);' "$SHARED" "$(id -u agent)" "$(id -g browser)" ||
  echo "entrypoint: $SHARED is not a folder, so the browser's downloads and uploads have nowhere to go" >&2

dnum="${DISPLAY#:}"
rm -f "/tmp/.X${dnum}-lock" "/tmp/.X11-unix/X${dnum}"

PIDS=""
cleanup() {
  trap - INT TERM EXIT
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
}
trap 'cleanup; exit 143' INT TERM
trap cleanup EXIT
spawn() { name=$1; shift; "$@" >"$LOGDIR/$name.log" 2>&1 & PIDS="$PIDS $!"; }

spawn xvfb as_agent Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp
i=0
while [ ! -S "/tmp/.X11-unix/X${dnum}" ]; do
  i=$((i + 1)); [ "$i" -le 100 ] || { echo "Xvfb never came up" >&2; cat "$LOGDIR/xvfb.log" >&2; exit 1; }
  sleep 0.1
done
spawn openbox as_agent openbox
# The first synthetic key combo after X starts is dropped; prime it.
sleep 0.5; (as_agent xdotool key shift) >/dev/null 2>&1 || true

# Before anything of the agent's runs, so DevTools' port is the browser's from the start.
spawn chromium as_browser node "$GUEST/cdp.mjs"
spawn browser-spawner as_browser node "$GUEST/spawner.mjs"
spawn x11vnc as_agent x11vnc -display "$DISPLAY" -localhost -rfbport 5900 -nopw -forever -shared -noxdamage
spawn websockify as_agent websockify 127.0.0.1:6080 127.0.0.1:5900
spawn spawner as_agent node "$GUEST/spawner.mjs"
spawn desk as_desk node "$GUEST/server.js"
spawn relay as_relay node "$GUEST/sprite-relay.mjs"

echo "started:$PIDS"
while :; do
  for p in $PIDS; do
    if ! kill -0 "$p" 2>/dev/null; then
      echo "child $p exited; shutting down" >&2
      for f in "$LOGDIR"/*.log; do echo "--- $f" >&2; tail -n 20 "$f" >&2; done
      exit 1
    fi
  done
  sleep 2
done
