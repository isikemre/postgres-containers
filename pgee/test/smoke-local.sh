#!/bin/sh
# Smoke test of a PGEE image without Kubernetes: creates an encrypted primary
# through the initdb wrapper, a pg_basebackup replica, promotes the replica
# while the old primary keeps writing (split brain), then rewinds the old
# primary and lets it follow the new one, as CloudNativePG would.
#
#   key=$(openssl rand -hex 32); echo "$key" > /tmp/dek.hex; chmod 644 /tmp/dek.hex
#   docker run --rm -v "$PWD/pgee/test:/t:ro" -v /tmp/dek.hex:/dek.hex:ro \
#     -e TDE_KEY_SOURCE=file -e TDE_KEY_FILE=/dek.hex <image> /t/smoke-local.sh
set -eu
cd /tmp
B=/var/lib/postgresql
export PGHOST=/tmp
start() { pg_ctl -D "$1" -o "-p $2 -k /tmp -c listen_addresses=''" -l "$1.log" -w start >/dev/null; }
q() { psql -p "$1" -XAtq -c "$2"; }
fail() {
	echo "FAIL  $*"
	exit 1
}

echo "== initdb through the wrapper (TDE_KEY_SOURCE=$TDE_KEY_SOURCE)"
export PGDATA=$B/p1
initdb --username postgres -D "$PGDATA" -k >/tmp/initdb.log 2>&1 || {
	cat /tmp/initdb.log
	fail initdb
}
grep -q "Data encryption is enabled" /tmp/initdb.log || fail "initdb did not encrypt"
grep "^encryption_key_command" "$PGDATA/postgresql.conf"
pg_controldata "$PGDATA" | grep -E "^(Data encryption|Encryption key length)"
printf 'wal_log_hints = on\nwal_keep_size = 512MB\n' >>"$PGDATA/postgresql.conf"
echo "local replication all trust" >>"$PGDATA/pg_hba.conf"
start "$PGDATA" 5432
q 5432 "create table t(x text); insert into t values('PLAINTEXT_MARKER_4711'); checkpoint;"
F=$(q 5432 "select pg_relation_filepath('t')")
[ "$(grep -c PLAINTEXT_MARKER_4711 "$PGDATA/$F" || true)" = 0 ] || fail "plaintext in heap file"
echo "OK    no plaintext in heap file"

echo "== replica from pg_basebackup"
pg_basebackup -p 5432 -D $B/p2 -R -X stream
start $B/p2 5433
[ "$(q 5433 'select pg_is_in_recovery()')" = t ] || fail "replica not in recovery"
echo "OK    replica streaming, tdekey.json: $(test -f $B/p2/tdekey.json && echo copied || echo n/a)"

echo "== split brain, then pg_rewind of the old primary"
pg_ctl -D $B/p2 -w promote >/dev/null
q 5433 "insert into t values('after-promote'); checkpoint;"
q 5432 "insert into t select 'lost' from generate_series(1,1000); checkpoint;"
pg_ctl -D $B/p1 -m fast -w stop >/dev/null
pg_rewind --source-server "port=5433 host=/tmp user=postgres dbname=postgres" \
	--target-pgdata $B/p1 >/tmp/rewind.log 2>&1 || {
	cat /tmp/rewind.log
	fail pg_rewind
}
tail -1 /tmp/rewind.log
touch $B/p1/standby.signal
echo "primary_conninfo = 'port=5433 host=/tmp user=postgres'" >>$B/p1/postgresql.auto.conf
start $B/p1 5432
sleep 2
[ "$(q 5432 "select string_agg(x, ',' order by x) from t")" = "PLAINTEXT_MARKER_4711,after-promote" ] ||
	fail "old primary did not follow the new one"
echo "OK    old primary rewound and following"
echo "== passed"
