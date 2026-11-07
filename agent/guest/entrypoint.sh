#!/bin/sh
# The entrypoint of an agent's Sprite (Dockerfile.agent), after an existing
# etc/sprites/an existing browser desktop/entrypoint.sh. POSIX sh supervisor for the screen
# and the relay:
#
#   Xvfb :99 -> openbox -> Chromium (profile in the home folder, CDP on
#   127.0.0.1:9222) -> x11vnc 127.0.0.1:5900 -> websockify 127.0.0.1:6080;
#   server.js (an existing desktop control server, control-only) on
#   127.0.0.1:8090 with a bearer made at each boot; sprite-relay.mjs on $PORT.
#
# Every listener but the relay binds the guest's own loopback. Chromium keeps
# its sandbox. Exits 1 as soon as a child other than Chromium dies; the
# platform restarts the entrypoint. The platform does not apply the image's
# ENV, so everything is defaulted here.
set -eu
export HOME="${HOME:-/home/avery}"
export DISPLAY="${DISPLAY:-:99}" TZ="${TZ:-America/Los_Angeles}"
GUEST=/opt/avery
PROFILE="$HOME/.config/chromium"
LOGDIR=/tmp/avery-logs
mkdir -p "$PROFILE" "$LOGDIR"

dnum="${DISPLAY#:}"; dnum="${dnum%%.*}"
rm -f "/tmp/.X${dnum}-lock" "/tmp/.X11-unix/X${dnum}" 2>/dev/null || true

# The desktop control server's bearer: new at each boot, readable only by this
# user (the agent's shell, which drives the screen through agent/guest/desk.mjs).
umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$HOME/.desk-token"
umask 022

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

spawn xvfb Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp
i=0
while [ ! -S "/tmp/.X11-unix/X${dnum}" ]; do
  i=$((i + 1)); [ "$i" -le 100 ] || { echo "Xvfb never came up" >&2; cat "$LOGDIR/xvfb.log" >&2; exit 1; }
  sleep 0.1
done
spawn openbox openbox
# The first synthetic key combo after X starts is dropped; prime it.
sleep 0.5; xdotool key shift >/dev/null 2>&1 || true

# Chromium, started again if a person closes it. server.js readies the
# profile each time (stale Singleton locks cleared, marked cleanly exited,
# restore_on_startup set) and gives its flags: --disable-gpu,
# --disable-gpu-shader-disk-cache, the previous tabs on a used profile.
browser() {
  while :; do
    args=$(PI_DESKTOP_PROFILE_DIR="$PROFILE" node --input-type=module -e "
      const desk = await import('$GUEST/server.js');
      const { restore, running } = desk.prepareProfile();
      if (!running) process.stdout.write(desk.chromiumArgs({ restore }).join('\n'));")
    if [ -n "$args" ]; then
      # One flag per line, none with spaces.
      # shellcheck disable=SC2086
      (IFS='
'; exec chromium $args --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222)
    fi
    sleep 2
  done
}
spawn chromium browser
spawn x11vnc x11vnc -display "$DISPLAY" -localhost -rfbport 5900 -nopw -forever -shared -noxdamage
spawn websockify websockify 127.0.0.1:6080 127.0.0.1:5900
spawn desk env PI_DESKTOP_TOKEN="$(cat "$HOME/.desk-token")" PI_DESKTOP_SUPERVISE=0 PI_DESKTOP_HOST=127.0.0.1 \
  PORT=8090 PI_DESKTOP_WIDTH=1280 PI_DESKTOP_HEIGHT=800 node "$GUEST/server.js"
spawn relay node "$GUEST/sprite-relay.mjs"

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
