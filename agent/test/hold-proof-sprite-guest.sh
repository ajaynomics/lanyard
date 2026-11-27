#!/bin/sh
# The Sprite half of bin/check-hold-proof-sprite, run as root inside a
# throwaway Sprite made from the hold-proof image. It checks the computer the
# platform booted (the hold came up there, under the platform's own start),
# then stops it and the platform's restarter, so that hold-proof-check.mjs can
# start the computer itself exactly as it does under Docker. The check's
# assertions are unchanged; what differs is the machine: a Sprite's kernel,
# init and restarter instead of a container's.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
# The computer's logs live on the guest's tmpfs and go when the Sprite stops,
# so they are printed on the way out, pass or fail: the hold's says why it
# refused a request or closed its relay.
logs() {
  for log in /run/sprite-logs/*.log; do
    [ -f "$log" ] || continue
    echo "--- $log ($(wc -c < "$log") bytes, last 64 KB)"
    tail -c 65536 "$log"
  done
  echo "---"
}
trap logs EXIT

[ "$(id -u)" = 0 ] || fail "run as root inside the Sprite"
[ $# = 1 ] || fail "usage: hold-proof-sprite-guest.sh <sha256 of hold-proof-check.mjs>"
got=$(sha256sum /proof/hold-proof-check.mjs | cut -d' ' -f1)
[ "$got" = "$1" ] || fail "hold-proof-check.mjs arrived as $got, not $1"
echo "sprite=$(hostname) kernel=$(uname -r) check_sha256=$got"

# 1. The computer the platform started. Its start script exits at the first
# thing the hold cannot have (nftables, tmpfs), so a hold that is up proves the boot.
state=$(cat /run/sprite-entrypoint.state 2>/dev/null || echo missing)
[ "$state" = running ] || fail "the platform's start is '$state', not running"
[ -f /opt/agent/hold/boot.sh ] || fail "this image has no browser hold (/opt/agent/hold/boot.sh)"
i=0
until [ -f /dev/shm/browser-hold/private/ready ]; do
  i=$((i + 1)); [ "$i" -le 120 ] || fail "the hold never came up under the platform's start"
  sleep 1
done
[ "$(stat -f -c %t /dev/shm)" = 1021994 ] || fail "/dev/shm is not tmpfs"
nft list table inet browser_hold > /dev/null || fail "no browser_hold nftables table"
hold=$(pgrep -u hold -f /opt/agent/hold/run.mjs) || fail "no hold proxy running as the hold user"
pass "the platform booted the computer with the hold: tmpfs, nftables table, proxy $hold as hold"

# What this Sprite runs, to compare with the same files copied out of the image by digest.
echo "--- checksums"
sha256sum /opt/agent/entrypoint.sh /opt/agent/sprite-relay.mjs /opt/agent/cdp.mjs /opt/agent/spawner.mjs \
  /opt/agent/hold/*.mjs /opt/agent/hold/*.sh /opt/agent/hold/*.json /etc/chromium/policies/managed/*.json
echo "---"

# 2. Stop the restarter first, then the computer, so that nothing comes back
# while the check runs its own: the platform restarts in 1 s, then 2, 4...
# Its pid is read before the stop, which may remove the file.
loop=$(cat /run/sprite-entrypoint-openrc.pid 2>/dev/null) || fail "no /run/sprite-entrypoint-openrc.pid: the platform's restarter is not where this check stops it"
case "$loop" in ''|*[!0-9]*) fail "/run/sprite-entrypoint-openrc.pid holds '$loop', not a pid" ;; esac
rc-service sprite-entrypoint stop > /dev/null
i=0
while [ -d "/proc/$loop" ]; do
  i=$((i + 1)); [ "$i" -le 30 ] || fail "the platform's restarter did not stop"
  sleep 0.5
done
# Never PID 1: that is the Sprite's init.
computer() { ps -o pid,user,args | awk '$1 != 1' | grep -E '/opt/agent/|Xvfb|x11vnc|websockify|openbox|chromium|pi-env' | grep -v grep || true; }
for pid in $(pgrep -f /opt/agent/entrypoint.sh || true); do [ "$pid" = 1 ] || kill -TERM "$pid" || true; done
i=0
while [ -n "$(computer)" ] && [ "$i" -lt 30 ]; do i=$((i + 1)); sleep 0.5; done
if [ -n "$(computer)" ]; then
  echo "NOTE: killing what the computer's own stop left running:"
  computer
  for pid in $(computer | awk '{print $1}'); do kill -KILL "$pid" || true; done
  sleep 1
fi
[ -z "$(computer)" ] || { computer; fail "the platform's computer would not stop"; }
# The check starts from a computer that never ran, as a container's is: its
# hold's state and rules from the platform's boot go (the next boot makes both).
rm -rf /dev/shm/browser-hold
nft delete table inet browser_hold
pass "stopped the platform's restarter and its computer, and cleared its hold's state"

# 3. The Docker check, unchanged, on this Sprite.
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -days 1 \
  -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' \
  -keyout /proof/site.key -out /proof/site.pem > /dev/null 2>&1
umask 022
set +e
(cd / && node /proof/hold-proof-check.mjs)
code=$?
set -e

# The check trusts its fixture site system-wide; this Sprite is kept, so undo that.
rm -f /usr/local/share/ca-certificates/hold-test-origin.crt /proof/site.key
update-ca-certificates > /dev/null 2>&1 || true
echo "exit=$code"
exit "$code"
