#!/bin/sh
# Acceptance test for a PGEE TDE cluster running under CloudNativePG.
# Needs kubectl only (no cnpg plugin). Destructive: it switches over, kills
# the primary and scales the cluster out by one instance. Use a test cluster.
#
#   pgee/test/verify-tde.sh <cluster> [namespace]
set -eu

C=${1:?usage: $0 <cluster> [namespace]}
NS=${2:-$(kubectl config view --minify -o jsonpath='{..namespace}')}
NS=${NS:-default}
PGDATA=/var/lib/postgresql/data/pgdata

k() { kubectl -n "$NS" "$@"; }
primary() { k get cluster "$C" -o jsonpath='{.status.currentPrimary}'; }
instances() { k get pods -l "cnpg.io/cluster=$C,cnpg.io/podRole=instance" -o jsonpath='{.items[*].metadata.name}'; }
sql() { k exec "$1" -c postgres -- psql -XAtq -c "$2"; }
ok() { echo "OK    $*"; }
fail() {
	echo "FAIL  $*"
	exit 1
}
# retry <seconds> <command...>: until the command succeeds or time runs out
retry() {
	t=$1
	shift
	while ! "$@" >/dev/null 2>&1; do
		t=$((t - 5))
		[ "$t" -gt 0 ] || return 1
		sleep 5
	done
}
in_recovery() { [ "$(sql "$1" 'select pg_is_in_recovery()')" = t ]; }
wait_ready() {
	sleep 5
	k wait --for=condition=Ready "cluster/$C" --timeout="${1:-600}s" >/dev/null ||
		fail "cluster $C not Ready"
}

check_all() {
	fps=
	for p in $(instances); do
		cd=$(k exec "$p" -c postgres -- pg_controldata "$PGDATA")
		echo "$cd" | grep -Eq '^Data encryption: +on' || fail "$p: data encryption is off"
		fp=$(echo "$cd" | sed -n 's/^Data encryption fingerprint: *//p')
		fps="$fps $fp"
		ok "$p: encrypted, key fingerprint $fp"
	done
	[ "$(echo "$fps" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l)" -eq 1 ] ||
		fail "instances use different keys:$fps"
	ok "all instances share one key"
}

echo "== T1 every instance is encrypted with the same key"
check_all
P=$(primary)
[ "$(sql "$P" 'show data_encryption')" = on ] || fail "data_encryption is off"
ok "SHOW data_encryption = on"
echo "   encryption_key_command = $(sql "$P" 'show encryption_key_command')"

echo "== T2 no plaintext on disk"
sql "$P" "CREATE TABLE IF NOT EXISTS tde_probe(t text); INSERT INTO tde_probe VALUES ('PLAINTEXT_MARKER_4711'); CHECKPOINT;" >/dev/null
F=$(sql "$P" "select pg_relation_filepath('tde_probe')")
[ "$(k exec "$P" -c postgres -- sh -c "grep -c PLAINTEXT_MARKER_4711 $PGDATA/$F || true")" = 0 ] ||
	fail "plaintext found in $F"
ok "marker not in heap file $F"
[ "$(k exec "$P" -c postgres -- sh -c "grep -rl PLAINTEXT_MARKER_4711 $PGDATA/pg_wal/ /var/lib/postgresql/wal 2>/dev/null | wc -l")" = 0 ] ||
	fail "plaintext found in WAL"
ok "marker not in WAL"

echo "== T3 streaming replication"
n=$(sql "$P" "select count(*) from pg_stat_replication where state = 'streaming'")
[ "$n" -ge 1 ] || fail "no streaming replica"
ok "$n streaming replica(s)"

echo "== T4 switchover"
OLD=$(primary)
NEW=$(k get pods -l "cnpg.io/cluster=$C,cnpg.io/instanceRole=replica" -o jsonpath='{.items[0].metadata.name}')
k patch cluster "$C" --subresource=status --type=merge -p "{\"status\":{\"targetPrimary\":\"$NEW\"}}" >/dev/null
wait_ready
[ "$(primary)" = "$NEW" ] || fail "switchover to $NEW failed"
ok "primary is now $NEW"
retry 300 in_recovery "$OLD" || fail "former primary $OLD did not rejoin"
ok "former primary $OLD rejoined as replica"
sql "$NEW" "INSERT INTO tde_probe VALUES ('after-switchover')" >/dev/null

echo "== T5 failover (primary pod killed)"
OLD=$(primary)
k delete pod "$OLD" --grace-period=0 --force >/dev/null 2>&1
wait_ready 900
P=$(primary)
[ "$P" != "$OLD" ] && ok "failed over to $P" || ok "primary $P restarted in place"
k logs "$OLD" -c postgres 2>/dev/null | grep -q '"Starting up pg_rewind"' &&
	ok "$OLD ran pg_rewind" || echo "INFO  no pg_rewind in $OLD log (not needed this time)"
[ "$(sql "$P" "select count(*) from tde_probe where t = 'after-switchover'")" -ge 1 ] ||
	fail "data written after the switchover is missing"
ok "data intact"
retry 300 in_recovery "$OLD" || fail "$OLD did not rejoin as replica"
ok "$OLD rejoined as replica"

echo "== T6 scale out: a new replica joins via pg_basebackup"
N=$(k get cluster "$C" -o jsonpath='{.spec.instances}')
k patch cluster "$C" --type=merge -p "{\"spec\":{\"instances\":$((N + 1))}}" >/dev/null
wait_ready 900
check_all
k patch cluster "$C" --type=merge -p "{\"spec\":{\"instances\":$N}}" >/dev/null
wait_ready 900

echo "== passed. Not covered here: backup/restore, key service outage, KEK rotation (see PGEE.md)"
