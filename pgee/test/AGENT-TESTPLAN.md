# PGEE TDE acceptance test plan (for an agent)

You are testing CloudNativePG clusters that run CYBERTEC PGEE images with
Transparent Data Encryption (TDE). The images encrypt every new cluster; the
encryption key comes from a Kubernetes Secret (`TDE_KEY_SOURCE=file`). Your job
is to run the tests below in order and produce an evidence-backed report.

## How to work

- **Scope:** create, change and delete only resources in `$TEST_NS` whose
  names start with `pgee-` and that this plan creates. Production namespaces
  and clusters stay untouched.
- **Key secrecy:** the test key lives only in `~/pgee-test/*.key` and in
  Kubernetes Secrets. Keep it out of the report, the evidence and your
  messages.
- **Scripts:** every test is a code block that starts with `# file: <name>`.
  Save it under that name in `~/pgee-test/`, unchanged, and run it as
  `sh ~/pgee-test/<name> 2>&1 | tee ~/pgee-test/evidence/<name>.txt`.
  The script prints `PASS`, `FAIL` or `SKIP` and appends that line to
  `~/pgee-test/report.txt`. Its verdict is the result: record it as is.
- **On FAIL:** keep the evidence file, then continue with the next test,
  except where a test says **STOP**. On STOP, go straight to the Report.
- A test is done when its script has printed `PASS`, `FAIL` or `SKIP` and the
  evidence file exists.

## Step 0: setup

Ask the human for these values if you do not have them. Then write both files.

| Variable | Meaning |
|---|---|
| `TEST_NS` | Dedicated, existing test namespace |
| `IMAGE_17` | Full reference of the PGEE 17 image (licensed build, ideally `@sha256:` digest) |
| `IMAGE_18` | Full reference of the PGEE 18 image built from the same repository revision |
| `PULL_SECRET` | Image pull secret in `TEST_NS`, empty if not needed |
| `STORAGE_CLASS` | StorageClass for test volumes, empty for the default |
| `STORAGE_SIZE` | Volume size per instance, e.g. `2Gi` |
| `OBJECTSTORE` | Name of a ready Barman Cloud `ObjectStore` in `TEST_NS` for test T11, empty to skip T11 |

```sh
# file: pgee-test.env
TEST_NS=pgee-test
IMAGE_17=registry.example.com/db/postgresql-ee:17-minimal-trixie
IMAGE_18=registry.example.com/db/postgresql-ee:18-minimal-trixie
PULL_SECRET=
STORAGE_CLASS=
STORAGE_SIZE=2Gi
OBJECTSTORE=
```

```sh
# file: pgee-test-lib.sh
# Helpers shared by all tests. Sourced by every test script.
W=$HOME/pgee-test
. "$W/pgee-test.env"
REPORT=$W/report.txt
PGDATA_DIR=/var/lib/postgresql/data/pgdata

k() { kubectl -n "$TEST_NS" "$@"; }
pass() { echo "PASS $T $*" | tee -a "$REPORT"; exit 0; }
skip() { echo "SKIP $T $*" | tee -a "$REPORT"; exit 0; }
fail() { echo "FAIL $T $*" | tee -a "$REPORT"; exit 1; }

primary() { k get cluster "$1" -o jsonpath='{.status.currentPrimary}'; }
instances() { k get pods -l "cnpg.io/cluster=$1,cnpg.io/podRole=instance" -o jsonpath='{.items[*].metadata.name}'; }
replica() { k get pods -l "cnpg.io/cluster=$1,cnpg.io/instanceRole=replica" -o jsonpath='{.items[0].metadata.name}'; }
phase() { k get cluster "$1" -o jsonpath='{.status.phase}'; }
# sql <pod> <statement> [database]
sql() { k exec "$1" -c postgres -- psql -XAtq -d "${3:-postgres}" -c "$2"; }
controldata() { k exec "$1" -c postgres -- pg_controldata "$PGDATA_DIR"; }
encrypted() { controldata "$1" | grep -Eq '^Data encryption: +on'; }
fingerprint() { controldata "$1" | sed -n 's/^Data encryption fingerprint: *//p'; }
in_recovery() { [ "$(sql "$1" 'select pg_is_in_recovery()')" = t ]; }

# retry <seconds> <command...>: until the command succeeds or time runs out
retry() {
	t=$1
	shift
	while ! "$@" >/dev/null 2>&1; do
		t=$((t - 10))
		[ "$t" -gt 0 ] || return 1
		sleep 10
	done
}
ready() { [ "$(k get cluster "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; }
# wait_ready <cluster> [seconds]
wait_ready() {
	sleep 20
	retry "${2:-900}" ready "$1"
}

# all_encrypted <cluster>: every instance encrypted, one shared fingerprint.
# Prints one line per instance.
all_encrypted() {
	fps=
	for p in $(instances "$1"); do
		encrypted "$p" || { echo "$p: NOT encrypted"; return 1; }
		fp=$(fingerprint "$p")
		echo "$p: encrypted, fingerprint $fp"
		fps="$fps$fp
"
	done
	[ "$(printf '%s' "$fps" | sort -u | grep -c .)" -eq 1 ]
}

# new_key <file>: 256 bit random key as 64 hex characters, never printed
new_key() {
	umask 077
	head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$1"
}

# cluster_yaml <name> <image> <instances> <key-secret> <spec-snippet-file>
# Prints a Cluster manifest. The snippet holds extra spec fields (bootstrap,
# externalClusters, plugins), indented by two spaces.
cluster_yaml() {
	cat <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $1
  labels:
    pgee-test: "true"
spec:
  instances: $3
  imageName: $2
EOF
	if [ -n "${PULL_SECRET:-}" ]; then
		printf '  imagePullSecrets:\n    - name: %s\n' "$PULL_SECRET"
	fi
	cat "$5"
	cat <<EOF
  env:
    - name: TDE_KEY_SOURCE
      value: file
    - name: TDE_KEY_FILE
      value: /projected/pgee-tde/key
    - name: TDE_KEY_BITS
      value: "256"
  projectedVolumeTemplate:
    defaultMode: 0440
    sources:
      - secret:
          name: $4
          items:
            - key: key
              path: pgee-tde/key
  storage:
    size: $STORAGE_SIZE
EOF
	if [ -n "${STORAGE_CLASS:-}" ]; then
		printf '    storageClass: %s\n' "$STORAGE_CLASS"
	fi
}
```

Then run `mkdir -p ~/pgee-test/evidence` and start with T0.

## Tests

### T0 Preconditions (STOP on FAIL)

```sh
# file: t00-preconditions.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T00
date -u
kubectl version 2>&1 | head -3
kubectl get ns "$TEST_NS" >/dev/null 2>&1 || fail "namespace $TEST_NS does not exist"
op=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' | grep -m1 cloudnative-pg)
[ -n "$op" ] || fail "CloudNativePG operator not found"
echo "operator image: $op"
echo "node architectures: $(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}')"
for r in clusters.postgresql.cnpg.io secrets pods pods/exec; do
	[ "$(kubectl auth can-i create "$r" -n "$TEST_NS")" = yes ] || fail "no permission to create $r in $TEST_NS"
done
[ "$(kubectl auth can-i patch clusters.postgresql.cnpg.io/status -n "$TEST_NS")" = yes ] ||
	fail "no permission to patch cluster status (needed for switchover)"
if kubectl get crd objectstores.barmancloud.cnpg.io >/dev/null 2>&1; then
	echo "barman cloud plugin: installed"
else
	echo "barman cloud plugin: not installed"
fi
left=$(k get cluster -l pgee-test=true -o name)
[ -z "$left" ] || fail "leftover test clusters, run Cleanup first: $left"
pass "kubectl, operator, permissions and namespace OK"
```

### T1 Image contents (STOP on FAIL)

Checks both images: PGEE full version (no demo), architecture, the TDE
wrapper, no APT repository or credential leftovers, and that `initdb` refuses
to run without a key and encrypts with one.

```sh
# file: t01-images.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T01
for m in 17 18; do
	eval "img=\$IMAGE_$m"
	pod=pgee-img-$m
	k delete pod "$pod" --ignore-not-found --wait=true >/dev/null
	{
		cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    pgee-test: "true"
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $img
      command: ["sleep", "900"]
EOF
		if [ -n "${PULL_SECRET:-}" ]; then
			printf '  imagePullSecrets:\n    - name: %s\n' "$PULL_SECRET"
		fi
	} | k apply -f - >/dev/null || fail "cannot create pod for $img"
	k wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null || fail "pod for $img not ready (pull problem?)"
	x() { k exec "$pod" -- sh -c "$1"; }
	echo "== $img"
	x 'uname -m; postgres --version'
	v=$(x "dpkg-query -W -f '\${Version}' postgresql-${m}ee")
	echo "postgresql-${m}ee $v"
	case $v in *~demo*) fail "$img contains PGEE demo packages (1 GB per table limit)" ;; esac
	[ "$(x 'command -v initdb')" = /usr/local/bin/initdb ] || fail "$img: initdb wrapper not first in PATH"
	x 'test -x /usr/local/bin/pgee-tde-key' || fail "$img: /usr/local/bin/pgee-tde-key missing"
	[ "$(x 'ls /etc/apt/sources.list.d')" = debian.sources ] || fail "$img: unexpected APT sources: $(x 'ls /etc/apt/sources.list.d')"
	[ -z "$(x 'ls -A /etc/apt/auth.conf.d')" ] || fail "$img: APT credentials left in the image"
	out=$(x 'initdb -D /tmp/nokey 2>&1; echo "exit=$?"')
	echo "$out" | grep -q 'exit=0' && fail "$img: initdb ran without a key"
	echo "$out" | grep -q 'TDE_KEY_SOURCE is not set' || fail "$img: unexpected initdb error without key: $out"
	echo "initdb without key: refused (expected)"
	out=$(x 'head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" >/tmp/k; TDE_KEY_SOURCE=file TDE_KEY_FILE=/tmp/k initdb -D /tmp/withkey 2>&1')
	echo "$out" | grep -q 'Data encryption is enabled' || fail "$img: initdb with key did not encrypt"
	echo "initdb with key: encrypted (expected)"
	k delete pod "$pod" --wait=false >/dev/null
done
pass "both images are full PGEE builds with the TDE wrapper"
```

### T2 Test keys

```sh
# file: t02-keys.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T02
new_key "$W/test.key"
new_key "$W/wrong.key"
for s in pgee-test-key:test.key pgee-test-wrongkey:wrong.key; do
	name=${s%%:*}
	file=${s##*:}
	k delete secret "$name" --ignore-not-found >/dev/null
	k create secret generic "$name" --from-file=key="$W/$file" >/dev/null || fail "cannot create secret $name"
	k label secret "$name" pgee-test=true >/dev/null
	k patch secret "$name" -p '{"immutable":true}' >/dev/null || fail "cannot make $name immutable"
done
[ "$(k get secret pgee-test-key -o jsonpath='{.immutable}')" = true ] || fail "secret is not immutable"
pass "secrets pgee-test-key and pgee-test-wrongkey created, immutable"
```

### T3 Bootstrap: 3 instances on PGEE 17 (STOP on FAIL)

```sh
# file: t03-bootstrap.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T03
cat >"$W/snip-initdb.yaml" <<'EOF'
  bootstrap:
    initdb:
      dataChecksums: true
EOF
cluster_yaml pgee-test "$IMAGE_17" 3 pgee-test-key "$W/snip-initdb.yaml" >"$W/pgee-test.yaml"
k apply -f "$W/pgee-test.yaml" || fail "cluster manifest rejected"
wait_ready pgee-test 1200 || {
	k get pods
	fail "cluster not Ready after 20 minutes, phase: $(phase pgee-test)"
}
k get pods -l cnpg.io/cluster=pgee-test
P=$(primary pgee-test)
sql "$P" "create table keep as select 'before'::text x, g from generate_series(1,100000) g" app >/dev/null ||
	fail "cannot write test data"
pass "3 instances Ready, primary $P, 100000 rows in app.keep"
```

### T4 Every instance encrypted with the same key

```sh
# file: t04-encryption.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T04
all_encrypted pgee-test || fail "not all instances encrypted with one key"
P=$(primary pgee-test)
[ "$(sql "$P" 'show data_encryption')" = on ] || fail "SHOW data_encryption is not on"
[ "$(sql "$P" 'show encryption_key_command')" = /usr/local/bin/pgee-tde-key ] || fail "unexpected encryption_key_command"
controldata "$P" | grep -E '^(Data page checksum version|Encryption key length)'
pass "all instances encrypted, one fingerprint, checksums on"
```

### T5 No plaintext on disk

```sh
# file: t05-plaintext.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T05
P=$(primary pgee-test)
sql "$P" "create table if not exists tde_probe(t text); insert into tde_probe values ('PLAINTEXT_MARKER_4711'); checkpoint;" >/dev/null
F=$(sql "$P" "select pg_relation_filepath('tde_probe')")
n=$(k exec "$P" -c postgres -- sh -c "grep -c PLAINTEXT_MARKER_4711 $PGDATA_DIR/$F || true")
[ "$n" = 0 ] || fail "plaintext marker found in heap file $F"
n=$(k exec "$P" -c postgres -- sh -c "grep -rl PLAINTEXT_MARKER_4711 $PGDATA_DIR/pg_wal/ /var/lib/postgresql/wal 2>/dev/null | wc -l")
[ "$n" = 0 ] || fail "plaintext marker found in WAL"
pass "marker absent from heap file $F and from WAL"
```

### T6 Streaming replication

```sh
# file: t06-replication.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T06
P=$(primary pgee-test)
sql "$P" "select application_name, state, sync_state from pg_stat_replication"
retry 300 sh -c "[ \"\$(kubectl -n $TEST_NS exec $P -c postgres -- psql -XAtq -c \"select count(*) from pg_stat_replication where state = 'streaming'\")\" = 2 ]" ||
	fail "expected 2 streaming replicas"
pass "2 replicas streaming"
```

### T7 Switchover

```sh
# file: t07-switchover.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T07
OLD=$(primary pgee-test)
NEW=$(replica pgee-test)
echo "switchover $OLD -> $NEW"
k patch cluster pgee-test --subresource=status --type=merge \
	-p "{\"status\":{\"targetPrimary\":\"$NEW\"}}" >/dev/null || fail "cannot request switchover"
wait_ready pgee-test 900 || fail "cluster not Ready after switchover"
[ "$(primary pgee-test)" = "$NEW" ] || fail "primary is $(primary pgee-test), expected $NEW"
retry 600 in_recovery "$OLD" || fail "former primary $OLD did not rejoin as replica"
sql "$NEW" "insert into tde_probe values ('after-switchover')" >/dev/null || fail "cannot write on new primary"
pass "primary moved to $NEW, $OLD rejoined as replica"
```

### T8 Failover (primary pod killed)

```sh
# file: t08-failover.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T08
OLD=$(primary pgee-test)
echo "killing primary $OLD"
k delete pod "$OLD" --grace-period=0 --force >/dev/null 2>&1
wait_ready pgee-test 1200 || fail "cluster not Ready after failover"
P=$(primary pgee-test)
echo "new primary: $P"
[ "$(sql "$P" "select count(*) from tde_probe where t = 'after-switchover'")" -ge 1 ] || fail "data lost"
retry 600 in_recovery "$OLD" || fail "$OLD did not rejoin as replica"
if k logs "$OLD" -c postgres 2>/dev/null | grep -q 'Starting up pg_rewind'; then
	echo "$OLD ran pg_rewind"
fi
all_encrypted pgee-test || fail "encryption state differs after failover"
pass "failover to $P, data intact, $OLD rejoined"
```

### T9 Scale out: a new replica joins with the same key

```sh
# file: t09-scaleout.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T09
k patch cluster pgee-test --type=merge -p '{"spec":{"instances":4}}' >/dev/null
wait_ready pgee-test 1200 || fail "4th instance did not become Ready"
all_encrypted pgee-test || fail "new instance uses a different key or is unencrypted"
k patch cluster pgee-test --type=merge -p '{"spec":{"instances":3}}' >/dev/null
wait_ready pgee-test 900 || fail "cluster not Ready after scaling back to 3"
pass "4th instance joined with the same key, scaled back to 3"
```

### T10 Physical clone: same key works, wrong key fails

```sh
# file: t10-clone.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T10
cat >"$W/snip-clone.yaml" <<'EOF'
  bootstrap:
    pg_basebackup:
      source: origin
  externalClusters:
    - name: origin
      connectionParameters:
        host: pgee-test-rw
        user: streaming_replica
        sslmode: verify-full
        dbname: postgres
      sslKey:
        name: pgee-test-replication
        key: tls.key
      sslCert:
        name: pgee-test-replication
        key: tls.crt
      sslRootCert:
        name: pgee-test-ca
        key: ca.crt
EOF
cluster_yaml pgee-clone-ok "$IMAGE_17" 1 pgee-test-key "$W/snip-clone.yaml" | k apply -f - >/dev/null
cluster_yaml pgee-clone-bad "$IMAGE_17" 1 pgee-test-wrongkey "$W/snip-clone.yaml" | k apply -f - >/dev/null
wait_ready pgee-clone-ok 900 || fail "clone with the right key did not become Ready"
[ "$(sql pgee-clone-ok-1 'select count(*) from keep' app)" = 100000 ] || fail "clone with the right key has wrong data"
encrypted pgee-clone-ok-1 || fail "clone is not encrypted"
echo "clone with right key: Ready, 100000 rows, encrypted"
retry 600 sh -c "kubectl -n $TEST_NS get pods -o name | grep -q pgee-clone-bad-1-pgbasebackup" || fail "no clone job for the wrong key"
sleep 60
ready pgee-clone-bad && fail "clone with the WRONG key became Ready"
logs=$(for p in $(k get pods -o name | grep pgee-clone-bad-1-pgbasebackup); do k logs "$p" 2>/dev/null; done)
echo "$logs" | grep -q 'invalid encryption key' || fail "wrong-key clone failed, but not with 'invalid encryption key'"
echo "clone with wrong key: refused with 'invalid encryption key'"
k delete cluster pgee-clone-ok pgee-clone-bad --wait=false >/dev/null
pass "same key clones, wrong key is refused"
```

### T11 Backup and restore with the Barman Cloud plugin (optional)

Runs only when `OBJECTSTORE` is set. It takes a backup of a fresh cluster,
writes more data, then restores into a new cluster with the same key,
including WAL replay.

```sh
# file: t11-backup.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T11
[ -n "${OBJECTSTORE:-}" ] || skip "OBJECTSTORE not set"
k get objectstores.barmancloud.cnpg.io "$OBJECTSTORE" >/dev/null || fail "ObjectStore $OBJECTSTORE not found in $TEST_NS"
RUN=$(date +%s)
SRC=pgee-bkp-$RUN
DST=pgee-rst-$RUN
cat >"$W/snip-bkp.yaml" <<EOF
  bootstrap:
    initdb:
      dataChecksums: true
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: $OBJECTSTORE
EOF
cluster_yaml "$SRC" "$IMAGE_17" 1 pgee-test-key "$W/snip-bkp.yaml" | k apply -f - >/dev/null
wait_ready "$SRC" 900 || fail "$SRC not Ready"
retry 600 sh -c "[ \"\$(kubectl -n $TEST_NS get cluster $SRC -o jsonpath='{.status.conditions[?(@.type==\"ContinuousArchiving\")].status}')\" = True ]" ||
	fail "WAL archiving not working on $SRC"
sql "$SRC-1" "create table keep as select 'in-backup'::text x from generate_series(1,1000)" app >/dev/null
cat <<EOF | k apply -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $SRC-backup
  labels:
    pgee-test: "true"
spec:
  cluster:
    name: $SRC
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
retry 1200 sh -c "[ \"\$(kubectl -n $TEST_NS get backup $SRC-backup -o jsonpath='{.status.phase}')\" = completed ]" ||
	fail "backup did not complete, phase: $(k get backup "$SRC-backup" -o jsonpath='{.status.phase}')"
echo "backup completed"
sql "$SRC-1" "insert into keep select 'after-backup' from generate_series(1,10); select pg_switch_wal();" app >/dev/null
sleep 60
cat >"$W/snip-rst.yaml" <<EOF
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: $OBJECTSTORE
          serverName: $SRC
EOF
cluster_yaml "$DST" "$IMAGE_17" 1 pgee-test-key "$W/snip-rst.yaml" | k apply -f - >/dev/null
wait_ready "$DST" 1800 || fail "restore cluster $DST not Ready"
encrypted "$DST-1" || fail "restored cluster not encrypted"
[ "$(fingerprint "$DST-1")" = "$(fingerprint "$SRC-1")" ] || fail "restored cluster has a different key fingerprint"
n=$(sql "$DST-1" "select count(*) from keep" app)
a=$(sql "$DST-1" "select count(*) from keep where x = 'after-backup'" app)
echo "restored rows: $n (after-backup: $a)"
[ "$n" -ge 1000 ] || fail "restored data incomplete"
[ "$a" = 10 ] || fail "WAL written after the backup was not replayed"
k delete cluster "$SRC" "$DST" --wait=false >/dev/null
pass "backup and restore with WAL replay OK, same key, encrypted (object store prefix $SRC remains)"
```

### T12 Major upgrade by logical import into PGEE 18

```sh
# file: t12-import.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T12
k patch cluster pgee-test --type=merge -p '{"spec":{"enableSuperuserAccess":true}}' >/dev/null
retry 300 k get secret pgee-test-superuser || fail "superuser secret not created"
cat >"$W/snip-import.yaml" <<'EOF'
  bootstrap:
    initdb:
      dataChecksums: true
      import:
        type: monolith
        databases: ["*"]
        roles: ["*"]
        source:
          externalCluster: pgee-17
  externalClusters:
    - name: pgee-17
      connectionParameters:
        host: pgee-test-rw
        user: postgres
        dbname: postgres
      password:
        name: pgee-test-superuser
        key: password
EOF
cluster_yaml pgee-import "$IMAGE_18" 2 pgee-test-key "$W/snip-import.yaml" | k apply -f - >/dev/null
wait_ready pgee-import 1800 || fail "import cluster not Ready, phase: $(phase pgee-import)"
P=$(primary pgee-import)
sql "$P" 'select version()'
sql "$P" 'select version()' | grep -q 'PostgreSQL 18' || fail "import cluster does not run PostgreSQL 18"
[ "$(sql "$P" 'select count(*) from keep' app)" = 100000 ] || fail "imported data incomplete"
all_encrypted pgee-import || fail "import cluster not encrypted with one key"
k delete cluster pgee-import --wait=false >/dev/null
pass "PGEE 17 -> 18 by import: 100000 rows, encrypted"
```

### T13 Major upgrade in place, 17 → 18 (last test, destructive)

CloudNativePG upgrades in place when the image changes to a higher major
version. PGEE 18 `pg_upgrade` has a known defect: it does not pass the key to
`pg_resetwal --char-signedness`. That step runs on arm64 but is expected to be
skipped on amd64. This test shows which case applies here. A failed upgrade is
a valid, reportable result; the script then rolls the cluster back to 17.
**STOP** if the script prints `ROLLBACK FAILED`: leave all resources in place
for a human.

```sh
# file: t13-inplace-upgrade.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T13
echo "node architectures: $(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}')"
P=$(primary pgee-test)
FP=$(fingerprint "$P")
ROWS=$(sql "$P" 'select count(*) from keep' app)
echo "before: $(sql "$P" 'select version()'), fingerprint $FP, $ROWS rows"
k patch cluster pgee-test --type=merge -p "{\"spec\":{\"imageName\":\"$IMAGE_18\"}}" >/dev/null
result=
t=2400
while [ "$t" -gt 0 ]; do
	sleep 20
	t=$((t - 20))
	for j in $(k get pods -o name | grep major-upgrade); do
		[ "$(k get "$j" -o jsonpath='{.status.phase}')" = Failed ] && result=failed
	done
	[ -n "$result" ] && break
	if ready pgee-test && primary pgee-test >/dev/null && sql "$(primary pgee-test)" 'select version()' 2>/dev/null | grep -q 'PostgreSQL 18'; then
		result=upgraded
		break
	fi
done
echo "outcome: ${result:-timeout}"
if [ "$result" = upgraded ]; then
	wait_ready pgee-test 1200 || fail "upgraded, but cluster not Ready with all instances"
	P=$(primary pgee-test)
	sql "$P" 'select version()'
	[ "$(sql "$P" 'select count(*) from keep' app)" = "$ROWS" ] || fail "row count changed during upgrade"
	all_encrypted pgee-test || fail "not all instances encrypted after upgrade"
	[ "$(fingerprint "$P")" = "$FP" ] || fail "key fingerprint changed during upgrade"
	pass "in-place upgrade 17 -> 18 succeeded: data intact, encrypted, same key"
fi
echo "== upgrade job log (relevant lines)"
for j in $(k get pods -o name | grep major-upgrade); do
	k logs "$j" 2>&1 | grep -E 'char signedness|encryption key|Failure|error while running' | cut -c1-400
done
echo "== rolling back to $IMAGE_17"
k patch cluster pgee-test --type=merge -p "{\"spec\":{\"imageName\":\"$IMAGE_17\"}}" >/dev/null
if wait_ready pgee-test 1800 && [ "$(sql "$(primary pgee-test)" 'select count(*) from keep' app)" = "$ROWS" ]; then
	echo "rollback OK: cluster Ready on 17 with $ROWS rows"
	fail "in-place upgrade 17 -> 18 did not succeed (${result:-timeout}); rollback to 17 worked"
fi
echo "ROLLBACK FAILED"
fail "in-place upgrade failed AND rollback failed: STOP, keep resources for a human"
```

## Cleanup

Run after the last test, unless a test said STOP.

```sh
# file: t99-cleanup.sh
. "$HOME/pgee-test/pgee-test-lib.sh"
T=T99
k delete cluster -l pgee-test=true --wait=true
k delete backup -l pgee-test=true --ignore-not-found
k delete pod -l pgee-test=true --ignore-not-found
k delete secret -l pgee-test=true --ignore-not-found
rm -f "$W/test.key" "$W/wrong.key"
[ -z "$(k get cluster,secret,pod -l pgee-test=true -o name)" ] || fail "test resources left over"
pass "test resources and local keys removed"
```

## Report

Write `~/pgee-test/REPORT.md` for the human with:

1. Environment: date, operator image, node architectures, `IMAGE_17`,
   `IMAGE_18` (from T0 and T1 evidence).
2. A table with one row per test: test, `PASS`/`FAIL`/`SKIP`, the message from
   `report.txt`.
3. For every `FAIL`: the relevant lines from its evidence file, verbatim.
4. For T13: the outcome line and the upgrade job log lines, verbatim.
5. Anything you observed that the scripts did not check, marked as an
   observation.

Then hand `REPORT.md` and the `evidence/` directory to the human.
