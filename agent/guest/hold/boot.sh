# Sourced by the proof image only, before any browser process starts.
HOLD_DIR=/dev/shm/browser-hold
/opt/agent/hold/egress-rules.sh
[ "$(stat -f -c %t /dev/shm)" = 1021994 ] || { echo "browser hold requires tmpfs" >&2; exit 1; }
rm -rf "$HOLD_DIR"
mkdir -m 2750 "$HOLD_DIR"
chown hold:relay "$HOLD_DIR"
chmod 2750 "$HOLD_DIR"
mkdir -m 700 "$HOLD_DIR/private"
(umask 077; printf '%s' "$RELAY_SECRET" > "$HOLD_DIR/private/relay-key")
chown -R hold:hold "$HOLD_DIR/private"

as_hold() {
  ulimit -c 0
  exec env -i PATH="$PATH" NODE_USE_SYSTEM_CA=1 setpriv --reuid hold --regid hold --clear-groups \
    --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all "$@"
}
spawn hold as_hold node "$GUEST/hold/run.mjs"
i=0
while [ ! -f "$HOLD_DIR/private/ready" ]; do
  i=$((i + 1)); [ "$i" -le 100 ] || { echo "browser hold never came up" >&2; exit 1; }
  sleep 0.05
done

# Pipe only the public root into certutil as the browser UID; never alter
# system trust. An existing Linux NSS DB is kept across a computer restart.
(as_browser mkdir -p "$BROWSER_HOME/.pki/nssdb")
db="sql:$BROWSER_HOME/.pki/nssdb"
if [ ! -f "$BROWSER_HOME/.pki/nssdb/cert9.db" ]; then
  (as_browser certutil -N --empty-password -d "$db")
fi
if (as_browser certutil -L -d "$db" -n 'Browser Hold Local Authority') >/dev/null 2>&1; then
  (as_browser certutil -D -d "$db" -n 'Browser Hold Local Authority')
fi
(as_browser certutil -A -d "$db" -n 'Browser Hold Local Authority' -t 'C,,' < "$HOLD_DIR/private/root.pem")
