# CYBERTEC PGEE mit TDE als CloudNativePG-Operand

Dieser Fork baut neben den Community-Images optional Images mit
[CYBERTEC PostgreSQL Enterprise Edition](https://deb.cybertec-postgresql.com/)
(PGEE). Jeder Cluster, den ein solches Image anlegt, ist mit Transparent Data
Encryption (TDE) verschlüsselt. Am CloudNativePG-Operator ändert sich nichts.

Ohne `pgEdition` baut das Repo exakt die Upstream-Images. Die EE-Variante wird
mit `pgEdition=ee` eingeschaltet.

## TDE, `-K` und Replicas

PGEE verschlüsselt Datenfiles **und** WAL mit einem Data Encryption Key (DEK).
`initdb -K <befehl>` legt einen verschlüsselten Cluster an und schreibt
`encryption_key_command = '<befehl>'` in die `postgresql.conf`. Ab dann holt
jeder Prozess, der den Schlüssel braucht, ihn über diesen Befehl.

`-K` braucht es also nur **ein einziges Mal**, beim `initdb` des ersten Primary.
Physische Replicas müssen denselben DEK haben wie der Primary, weil sie das
verschlüsselte WAL abspielen. Daraus folgt die eine Regel, auf die es ankommt:

> Der Key-Command muss auf jeder Instanz, in jedem Job-Pod und in jedem
> Restore **denselben** Schlüssel liefern. Er darf nie pro Pod einen neuen
> erzeugen.

| CNPG-Vorgang | Was passiert | TDE |
|---|---|---|
| `bootstrap.initdb` | CNPG ruft `initdb` über den PATH auf, der Wrapper im Image ergänzt `-K /usr/local/bin/pgee-tde-key --key-bits` | Cluster wird verschlüsselt angelegt, der Key-Command landet in der `postgresql.conf` |
| Start | `postgres` liest `encryption_key_command` | Key-Command liefert den DEK |
| Replica (`join`), Scale-out | `pg_basebackup` kopiert PGDATA samt `postgresql.conf` (und `tdekey.json`) | Kein `-K` nötig, die Replica holt denselben DEK aus derselben Quelle |
| Switchover/Failover | CNPG ruft `pg_rewind` ohne `-K` auf | PGEE-`pg_rewind` liest `encryption_key_command` selbst aus der Ziel-`postgresql.conf`, kein Wrapper nötig |
| Backup (Barman Cloud Plugin) | Dateien und WAL werden roh kopiert | Liegen verschlüsselt im Object Store |
| Restore, PITR, `bootstrap.pg_basebackup`, Replica-Cluster | Physische Kopie | Braucht Zugriff auf **denselben** Schlüssel wie die Quelle, sonst `FATAL: invalid encryption key` |
| Logischer Dump (`pg_dump`, auch `bootstrap.initdb.import`) | Liest über den Server | **Klartext**, TDE schützt nur Daten auf Disk |

Weil `-K` im Image steckt, braucht es kein deprecated
`bootstrap.initdb.options`. `dataChecksums` und die übrigen `initdb`-Felder
bleiben damit nutzbar.

## Was im Image steckt

Nur bei `PG_EDITION=ee`:

- `postgresql-NNee` und `pgee-key-manager` (mindestens 2026.10, prüft der Build)
  aus dem CYBERTEC-Repo. Das PGDG-Repo wird dann nicht eingebunden. Die
  Extensions im `standard`-Image (pgaudit, pgvector, pg-failover-slots, JIT bei
  18) kommen gleichnamig von CYBERTEC und sind gegen EE gebaut.
- [`/usr/local/bin/initdb`](pgee/bin/initdb): ergänzt `-K` und `--key-bits`.
  Lässt `--sync-only` und ein selbst übergebenes `-K` unverändert durch. Ein
  Opt-out gibt es nicht.
- [`/usr/local/bin/pgee-tde-key`](pgee/bin/pgee-tde-key): der Key-Command.
  Woher der Schlüssel kommt, steuern Env-Variablen in der Cluster-Spec.

Der Typ `system` (Barman Cloud aus PyPI, deprecated) wird für EE nicht gebaut.
Für Backups ist das
[Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/) gedacht.

## Schlüsselquelle zur Laufzeit

Die Variablen heißen `TDE_*` und nicht `PGEE_*`: Der CNPG-Webhook lehnt in
`spec.env` alles ab, was mit `PG` oder `CNPG_` beginnt.

| Variable | Bedeutung |
|---|---|
| `TDE_KEY_SOURCE` | `file` oder `key-manager`, Pflicht (fail-closed) |
| `TDE_KEY_FILE` | `file`: Pfad zum Hex-DEK, typischerweise ein Secret unter `/projected` |
| `TDE_KEY_MANAGER_ARGS` | `key-manager`: Backend-Flags für `pgee_key_manager`, z. B. `-vault -vault-mount pgee -vault-path db/pgee-vault` |
| `VAULT_TOKEN_FILE` | `key-manager`: optional, wird bei jedem Aufruf nach `VAULT_TOKEN` gelesen |
| `TDE_KEY_BITS` | 128, 192 oder 256, Default 256. Nach dem Bootstrap nie mehr ändern |

Weitere Variablen, die das Backend liest (`VAULT_ADDR`, `VAULT_CACERT`,
Conjur-, Azure- oder KMIP-Parameter), kommen ebenfalls aus `spec.env`.

**`file`** (empfohlen für air-gapped Umgebungen), Beispiel:
[`pgee/examples/cluster-secret-key.yaml`](pgee/examples/cluster-secret-key.yaml)
Der DEK liegt als Kubernetes-Secret vor, alle Pods mounten dasselbe. Das ist
am einfachsten und braucht keinen externen Dienst. Backups enthalten keinen
Schlüssel. Regeln für den Betrieb:

- **Key Escrow:** Den Schlüssel einmal erzeugen (`openssl rand -hex 32`) und
  sofort außerhalb von Kubernetes hinterlegen, z. B. im Passwort-Safe oder
  HSM. Geht er verloren, sind die Datenbank und alle Backups weg.
- **Secret `immutable: true`:** Eine Änderung fiele sonst erst beim nächsten
  Pod-Neustart auf, wenn die Instanz nicht mehr startet. Das Secret gehört
  nicht dem Cluster und wird beim Löschen des Clusters nicht mit entfernt.
  So soll es auch bleiben.
- **Restore und DR:** Jeder Restore- oder Replica-Cluster braucht dasselbe
  Secret in seinem Namespace, auch in einem zweiten Kubernetes-Cluster.
- **Schutz:** Der Schutz hängt am Secret-Store. Prüfen, ob etcd Secrets
  verschlüsselt ablegt (EncryptionConfiguration), und
  `get secrets` sowie `pods/exec` im Namespace eng per RBAC vergeben.
  Wer eines davon darf, kann den Schlüssel lesen.
- **GitOps:** Den Schlüssel nie im Klartext ins Git legen, sondern z. B. über
  Sealed Secrets, SOPS oder External Secrets.
- **Keine Rotation:** Der DEK lässt sich nicht rotieren. Ist er kompromittiert,
  hilft nur ein neuer Cluster mit neuem Schlüssel per `bootstrap.initdb.import`.

**`key-manager`**, Beispiel: [`pgee/examples/cluster-vault.yaml`](pgee/examples/cluster-vault.yaml)
`pgee_key_manager` erzeugt den DEK beim `initdb` und legt ihn verschlüsselt
in `$PGDATA/tdekey.json` ab. Das Passwort dazu liegt in Vault/OpenBao (KV v2),
alternativ wird der DEK über Conjur, KMIP oder Cloud-KMS gewrappt.
`tdekey.json` reist mit `pg_basebackup` und mit jedem Backup mit, deshalb
brauchen Replicas und Restores nur Zugriff auf denselben Vault-Pfad. Der KEK
lässt sich rotieren (`-rotate`). Alte Vault-Versionen dürfen nie gelöscht
werden, weil ältere Backups sie referenzieren. `-rotate` schreibt
`tdekey.json` nur auf der Instanz neu, auf der es läuft.

> Ohne Backend-Flags (`TDE_KEY_MANAGER_ARGS` leer) schützt `pgee_key_manager`
> den DEK intern (`"method":"local"`). Dann enthält jedes Backup einen
> benutzbaren Schlüssel. Das ist nur für Tests geeignet.

Ist die Schlüsselquelle nicht erreichbar, startet eine Instanz nicht, sie
landet im CrashLoop. Laufende Instanzen arbeiten weiter.

## Build

Für das CYBERTEC-Repo gibt es drei BuildKit-Secrets. Keines davon landet im
Image:

| Bake-Variable | Secret | Inhalt |
|---|---|---|
| `aptSources` | `apt_sources` | deb822-Datei, Vorlage: [`pgee/apt/cybertec.sources.example`](pgee/apt/cybertec.sources.example). `@VERSION_CODENAME@` wird durch die Distro ersetzt |
| `aptAuth` | `apt_auth` | Zugangsdaten, Vorlage: [`pgee/apt/auth.conf.example`](pgee/apt/auth.conf.example) |
| `aptKeyring` | `apt_keyring` | ASCII-armored Signierschlüssel, z. B. [cybertec-deb.asc](https://deb.cybertec-postgresql.com/assets/cybertec-deb.asc) |

Für air-gapped Umgebungen:

| Bake-Variable | Wirkung |
|---|---|
| `httpProxy`, `httpsProxy`, `noProxy` | Werden als `http_proxy`/`HTTP_PROXY` usw. an apt und pip im Build gereicht. Nicht gesetzt heißt nicht übergeben, ein Proxy aus `~/.docker/config.json` greift dann weiter |
| `baseImagePrefix` | Wird vor das Debian-Basisimage gesetzt, z. B. `registry.example.com/dockerhub/`, um über einen Registry-Mirror zu ziehen |

Proxy-Werte stehen mit `mode=max` in der Provenance-Attestation, deshalb keine
Zugangsdaten in die Proxy-URL schreiben. Die BuildKit-Instanz selbst braucht
den Proxy separat, wenn sie Basisimages direkt zieht, etwa über
`docker buildx create --driver-opt env.https_proxy=...`.

Die Secret-Dateien am besten unter `_pgee/` im Repo ablegen. Dieser Pfad ist
per `.gitignore` (`_*/`) ausgeschlossen, und Bake verlangt für Dateien
innerhalb des Repos kein `--allow=fs.read`.

```bash
pgEdition=ee \
environment=production \
registry=registry.example.com/db \
aptSources=_pgee/cybertec.sources \
aptAuth=_pgee/auth.conf \
aptKeyring=_pgee/cybertec-deb.asc \
httpProxy=http://proxy.example.com:3128 \
httpsProxy=http://proxy.example.com:3128 \
baseImagePrefix=registry.example.com/dockerhub/ \
  docker buildx bake --push postgresql-17-minimal-trixie
```

Das erzeugt `registry.example.com/db/postgresql-ee:17-minimal-trixie`,
`:17.11-minimal-trixie` und einen Tag mit Zeitstempel. Die EE-Versionen stehen
in `pgeeVersions` in der [`docker-bake.hcl`](docker-bake.hcl). Sie folgen dem
CYBERTEC-Repo, nicht `postgreSQLVersions`. Das Image ist lizenzpflichtig und
gehört nur in eine private Registry, nie in die öffentliche GitHub-CI dieses
Forks.

Demo-Pakete (`~demo`, 1 GB pro Tabelle) lehnt der Build ab. Für Tests mit dem
`public`-Repo: `--set '*.args.PGEE_ALLOW_DEMO=true'`.

Push in eine private Registry (z. B. Harbor):

- Die Bake-Ausgabe (OCI-Index mit SBOM- und Provenance-Attestation) braucht
  einen Builder mit `docker-container`-Treiber, der Standard-Treiber `docker`
  kann sie nicht exportieren:
  `docker buildx create --name pgee --driver docker-container --use`.
- Bake baut standardmäßig `linux/amd64` und `linux/arm64`. Ohne QEMU auf dem
  Build-Host nur die eigene Plattform bauen, etwa mit
  `--set '*.platform=linux/amd64'`.
- `docker login registry.example.com` vorher. Der Builder nimmt die
  Zugangsdaten aus `~/.docker/config.json`.
- Läuft der Builder mit Proxy (`--driver-opt env.https_proxy=...`), gehört die
  Registry in `env.no_proxy`.
- Signiert eine interne CA das Registry-Zertifikat, braucht BuildKit sie in
  einer `buildkitd.toml` (`[registry."registry.example.com"]` mit
  `ca = ["/etc/ssl/certs/internal-ca.pem"]`), übergeben mit
  `docker buildx create --buildkitd-config buildkitd.toml`.
- Im Cluster das Image per Digest referenzieren
  (`...:17-minimal-trixie@sha256:...`). Der Digest steht in der Bake-Ausgabe
  oder in `docker buildx imagetools inspect`.

## Testen

- [`pgee/test/smoke-local.sh`](pgee/test/smoke-local.sh) testet ein Image ohne
  Kubernetes: initdb über den Wrapper, eine Replica, Split-Brain mit
  `pg_rewind`.
- [`pgee/test/verify-tde.sh`](pgee/test/verify-tde.sh) `<cluster>` ist der
  Abnahmetest gegen einen laufenden CNPG-Cluster: Verschlüsselung und gleicher
  Key-Fingerprint auf allen Instanzen, kein Klartext auf Disk, Switchover,
  harter Failover, Scale-out. Er ist destruktiv und nur für Testcluster
  gedacht.
- [`pgee/test/AGENT-TESTPLAN.md`](pgee/test/AGENT-TESTPLAN.md) ist der
  vollständige Abnahmeplan T00–T13 (inklusive Klon, Backup/Restore, PITR,
  Import und In-place-Upgrade), geschrieben für einen Agenten, der ihn in der
  Zielumgebung abarbeitet und einen Report mit Evidenz erstellt.

Stand 05.11.2026 mit den PGEE-Demo-Paketen (17.11ee1.4.7, 18.6ee1.5.5,
pgee-key-manager 2026.10.06), linux/arm64, CloudNativePG 1.30.1 in kind und
k3d, jeweils mit `file` und mit `key-manager` + Vault:

- Bootstrap mit 3 Instanzen: alle verschlüsselt, ein Fingerprint, `tdekey.json`
  auf den Replicas
- Kein Klartext in Heap-File und WAL
- Switchover und harter Failover. CNPG führt `pg_rewind` aus,
  `pgee_key_manager` liest dabei aus Vault (Security-Context-Check akzeptiert)
- `pg_rewind` mit echter Divergenz (lokal)
- Scale-out 3 → 4: Die neue Replica hat denselben Key
- `bootstrap.pg_basebackup`-Klon: läuft mit demselben Key, scheitert mit einem
  anderen
- Vault-Token ungültig: Ein Replica-Neustart scheitert, der Primary läuft
  weiter, nach Korrektur erholt sich die Replica
- Backup über das Barman Cloud Plugin (RustFS als S3) und Restore in einen
  neuen Cluster mit demselben Secret: verschlüsselt, gleicher Fingerprint,
  WAL nach dem Backup wird eingespielt
- PITR (`recoveryTarget.targetTime`): stoppt am Zielzeitpunkt, Cluster danach
  beschreibbar. Restore desselben Backups mit falschem Key: abgelehnt mit
  `invalid encryption key`
- Object Store durchsucht: Ein Marker aus einer Tabelle steht weder in
  `data.tar` noch in den entpackten WAL-Segmenten, der Schlüssel auch nicht.
  Im selben Lauf enthält ein `pg_dump` den Marker im Klartext
- Build über einen HTTP-Proxy (Debian per HTTP, CYBERTEC per CONNECT)
- `docker buildx bake --push` mit Standard-Ausgabe (OCI-Index, SBOM,
  Provenance) in eine Registry, Pull per Digest durch k3d
- Major-Upgrade 17 → 18 in-place (CNPG `pg_upgrade`) auf arm64: **scheitert**,
  siehe unten. Rollback auf das 17er-Image stellt den Cluster wieder her
- Major-Upgrade 17 → 18 per `bootstrap.initdb.import` in einen neuen Cluster
  mit demselben Secret: funktioniert, verschlüsselt

Abnahme in einer air-gapped Zielumgebung (amd64, lizenzierte Pakete über einen
internen APT-Mirror, Basis Ubuntu 24.04, private Harbor, Cilium mit
Default-Deny) mit [`AGENT-TESTPLAN.md`](pgee/test/AGENT-TESTPLAN.md): T00–T13
bestanden, inklusive In-place-Upgrade 17 → 18.

Nicht getestet:

- KEK-Rotation
- PITR (T11b) in der Zielumgebung

## Grenzen

- **Kein offiziell unterstützter Pfad.** CNPG garantiert nur
  PostgreSQL-Versionen der PGDG. CYBERTEC bietet TDE auf Kubernetes über den
  eigenen Operator an. Eine Supportaussage von CYBERTEC für PGEE als
  CNPG-Operand sollte vor der Produktion schriftlich vorliegen.
- **Bestehende Cluster ohne TDE** lassen sich nicht nachträglich
  verschlüsseln. Sie werden logisch umgezogen, z. B. in einen neuen Cluster
  mit `bootstrap.initdb.import` (läuft über `initdb`, also verschlüsselt) oder
  per logischer Replikation.
- **Major-Upgrade in-place** (CNPG `pg_upgrade`, ausgelöst durch ein Image mit
  höherer Major-Version) auf PG 18: In PGEE (18.3ee bis 18.6ee1.5.5) steckt ein
  Bug. `pg_upgrade` gibt den Schlüssel allen `pg_resetwal`-Aufrufen über stdin
  mit, nur dem Aufruf `pg_resetwal --char-signedness` nicht. Der scheitert dann
  mit `could not read encryption key from stdin`, auch mit `-K` und auch ohne
  CNPG. Ob dieser Aufruf überhaupt stattfindet, hängt an der Plattform: Auf
  arm64 bei Quellversionen vor 18 ja, dort scheitert das Upgrade. Auf amd64
  wird der Schritt übersprungen, und das Upgrade läuft durch: mit
  `pg_upgrade` allein und über CNPG auf einem amd64-Cluster (17.11ee1.4.7 →
  18.6ee1.5.5, gleicher Fingerprint, kein Klartext auf Disk, siehe T13). Mit
  `--set-char-signedness` tritt der Fehler auch auf amd64 auf. Den Bug an
  CYBERTEC melden (bugs-ee@cybertec.at). Bis zum Fix gilt: auf amd64 das
  In-place-Upgrade vorher auf einem Testcluster mit T13 prüfen und davor ein
  frisches Backup ziehen (nach Erfolg gibt es nur noch Restore, kein Zurück), auf
  arm64 per `bootstrap.initdb.import` in einen neuen Cluster mit demselben
  Secret umziehen. Scheitert ein In-place-Upgrade, `imageName` bzw. den Katalog
  auf die alte Major-Version zurücksetzen. Im Modus `key-manager` erzeugt
  `initdb` für das neue Datenverzeichnis zudem einen neuen DEK, dort wäre ein
  In-place-Upgrade auch nach dem Fix nicht möglich.
- **NetworkPolicies:** Bei Default-Deny (z. B. Cilium) braucht der Namespace
  Freigaben: CNPG-Operator zu den Instanz-Pods auf 8000, Instanzen
  untereinander auf 5432 und 8000, Instanzen zur Kubernetes-API und zum Object
  Store. Das ist kein PGEE-Thema, fällt aber beim ersten Cluster auf.
- **Logische Dumps sind Klartext.** Ein `pg_dump` (auch per CronJob) braucht
  eigene Verschlüsselung, z. B. `age`/`gpg`, und ein Ziel mit
  Zugriffsschutz. `bootstrap.initdb.import` legt seine Dumps vorübergehend
  unverschlüsselt unter `/var/lib/postgresql/data/dumps` auf das PVC des neuen
  Clusters und löscht sie danach nur (kein Überschreiben). Wer das ausschließen
  muss, braucht Verschlüsselung auf Storage-Ebene.
- **Im physischen Backup bleiben lesbar:** Konfigurationsdateien
  (`pg_hba.conf`, `postgresql.conf` mit dem Pfad des Key-Commands, ohne
  Schlüssel), `backup.info` und die Metadaten in `pg_control`. Zusätzlich
  serverseitige Verschlüsselung im Object Store (`data.encryption` und
  `wal.encryption` im `ObjectStore`, wenn der S3-Dienst sie unterstützt) und
  TLS zum Endpunkt nutzen.
- **WAL-Kompression bringt kaum etwas,** verschlüsselte Seiten komprimieren
  schlecht. Ein volles WAL-Segment mit Daten liegt gzip-komprimiert bei rund
  12 von 16 MB. Den Object Store entsprechend dimensionieren.
- **DEK-Rotation** unterstützt PGEE nicht, rotierbar ist nur der KEK im Modus
  `key-manager`.

## Feste Verträge

Diese Dinge stecken in Datenverzeichnissen, Backups und Cluster-Specs. Künftige
Images müssen sie beibehalten, sonst lassen sich bestehende Cluster und alte
Backups nicht mehr starten:

- der Pfad `/usr/local/bin/pgee-tde-key` (steht in jeder `postgresql.conf`)
- die Variablen `TDE_KEY_SOURCE`, `TDE_KEY_FILE`, `TDE_KEY_BITS` und das
  Schlüsselformat (Hex)
- das Secret mit dem Schlüssel, solange es Daten oder Backups gibt

Vor jedem Update von CNPG, PGEE oder diesem Repo: Image bauen,
`smoke-local.sh` und auf einem Testcluster `verify-tde.sh` laufen lassen. Bei
CNPG-Updates gilt das besonders, weil die Lösung davon abhängt, dass CNPG
`initdb` über den PATH aufruft und `PG*`-Variablen reserviert.
