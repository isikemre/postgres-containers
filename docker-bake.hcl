variable "environment" {
  default = "testing"
  validation {
    condition = contains(["testing", "production"], environment)
    error_message = "environment must be either testing or production"
  }
}

variable "registry" {
  default = "localhost:5000"
}

// Use the revision variable to identify the commit that generated the image
variable "revision" {
  default = ""
}

fullname = ( environment == "testing") ? "${registry}/postgresql-testing" : "${registry}/postgresql"
now = timestamp()
authors = "The CloudNativePG Contributors"
url = "https://github.com/cloudnative-pg/postgres-containers"

// PostgreSQL versions to build
postgreSQLVersions = [
  "14.23",
  "15.18",
  "16.14",
  "17.10",
  "18.4"
]

// PostgreSQL preview versions to build, such as "18~beta1" or "18~rc1"
// Preview versions are automatically filtered out if present in the stable list
// MANUALLY EDIT THE CONTENT - AND UPDATE THE README.md FILE TOO
postgreSQLPreviewVersions = [
]

// Barman version to build
// renovate: datasource=pypi versioning=loose depName=barman
barmanVersion = "3.19.1"

// Optional suffix appended to the PostgreSQL APT package name.
// Leave empty ("") to install the official PGDG packages (e.g. postgresql-16).
// Set to "ee" to install enterprise edition packages instead
// (e.g. postgresql-16ee, postgresql-17ee, postgresql-18ee).
// NOTE: edition packages such as "ee" are NOT provided by the official PGDG
// repository (apt.postgresql.org). The corresponding APT repository must be
// reachable from the build and its configuration passed as BuildKit secrets
// (see below), otherwise the build fails with a package-not-found error.
variable "pgEdition" {
  default = ""
}

// Paths to optional APT sources / keyring files for the edition repository.
// These are injected into the build as BuildKit secrets and never appear in
// the image history or layers. Leave them empty ("") for official PGDG builds.
//
// pgEditionSources1: deb822 .sources file for the primary edition repository.
// pgEditionSources2: deb822 .sources file for a second edition repository.
// pgEditionKeyring:  GPG keyring referenced by Signed-By in a .sources file.
//                    Not needed when the .sources embeds the key inline.
//
// Example:
//   pgEdition=ee \
//   pgEditionSources1=vendor-main.sources \
//   pgEditionSources2=vendor-updates.sources \
//   pgEditionKeyring=vendor.gpg \
//     docker buildx bake --push
variable "pgEditionSources1" {
  default = ""
}
variable "pgEditionSources2" {
  default = ""
}
variable "pgEditionKeyring" {
  default = ""
}

// Extensions to be included in the `standard` image
extensions = [
  "pgaudit",
  "pgvector",
  "pg-failover-slots"
]

target "default" {
  matrix = {
    tgt = [
      "minimal",
      "standard",
      "system"
    ]
    // Get the list of PostgreSQL versions, filtering preview versions if already stable
    pgVersion = getPgVersions(postgreSQLVersions, postgreSQLPreviewVersions)
    base = [
      // renovate: datasource=docker versioning=loose
      "ubuntu:noble@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b"
    ]
  }
  platforms = [
    "linux/amd64",
    "linux/arm64"
  ]
  dockerfile = "Dockerfile"
  name = "postgresql-${index(split(".",cleanVersion(pgVersion)),0)}-${tgt}-${distroVersion(base)}"
  tags = concat([
    "${fullname}:${index(split(".",cleanVersion(pgVersion)),0)}-${tgt}-${distroVersion(base)}",
    "${fullname}:${cleanVersion(pgVersion)}-${tgt}-${distroVersion(base)}",
    "${fullname}:${cleanVersion(pgVersion)}-${formatdate("YYYYMMDDhhmm", now)}-${tgt}-${distroVersion(base)}",
  ], (tgt == "system" && distroVersion(base) == "bullseye" && isPreview(pgVersion) == false) ? getRollingTags("${fullname}", pgVersion) : [])
  context = "."
  target = "${tgt}"
  args = {
    PG_VERSION = "${pgVersion}"
    PG_MAJOR = "${getMajor(pgVersion)}"
    BASE = "${base}"
    EXTENSIONS = "${getExtensionsString(pgVersion, extensions)}"
    STANDARD_ADDITIONAL_POSTGRES_PACKAGES = "${getStandardAdditionalPostgresPackagesPerMajorVersion(getMajor(pgVersion))}"
    BARMAN_VERSION = "${barmanVersion}"
    PG_EDITION = "${pgEdition}"
  }
  // Edition APT sources and keyring are injected as BuildKit secrets so they
  // never leak into the image history. Each secret is only included when its
  // corresponding variable points to a real file.
  secret = compact([
    pgEditionSources1 != "" ? "id=pg_edition_sources1,src=${pgEditionSources1}" : "",
    pgEditionSources2 != "" ? "id=pg_edition_sources2,src=${pgEditionSources2}" : "",
    pgEditionKeyring  != "" ? "id=pg_edition_keyring,src=${pgEditionKeyring}"    : "",
  ])
  output = [
    "type=image,oci-mediatypes=true,oci-artifact=true",
  ]
  attest = [
    "type=provenance,mode=max",
    "type=sbom"
  ]
  annotations = [
    "index,manifest:org.opencontainers.image.created=${now}",
    "index,manifest:org.opencontainers.image.url=${url}",
    "index,manifest:org.opencontainers.image.source=${url}",
    "index,manifest:org.opencontainers.image.version=${pgVersion}",
    "index,manifest:org.opencontainers.image.revision=${revision}",
    "index,manifest:org.opencontainers.image.vendor=${authors}",
    "index,manifest:org.opencontainers.image.title=CloudNativePG PostgreSQL ${pgVersion} ${tgt}",
    "index,manifest:org.opencontainers.image.description=A ${tgt} PostgreSQL ${pgVersion} container image",
    "index,manifest:org.opencontainers.image.documentation=${url}",
    "index,manifest:org.opencontainers.image.authors=${authors}",
    "index,manifest:org.opencontainers.image.licenses=Apache-2.0",
    "index,manifest:org.opencontainers.image.base.name=docker.io/library/ubuntu:${tag(base)}",
    "index,manifest:org.opencontainers.image.base.digest=${digest(base)}"
  ]
  labels = {
    "org.opencontainers.image.created" = "${now}",
    "org.opencontainers.image.url" = "${url}",
    "org.opencontainers.image.source" = "${url}",
    "org.opencontainers.image.version" = "${pgVersion}",
    "org.opencontainers.image.revision" = "${revision}",
    "org.opencontainers.image.vendor" = "${authors}",
    "org.opencontainers.image.title" = "CloudNativePG PostgreSQL ${pgVersion} ${tgt}",
    "org.opencontainers.image.description" = "A ${tgt} PostgreSQL ${pgVersion} container image",
    "org.opencontainers.image.documentation" = "${url}",
    "org.opencontainers.image.authors" = "${authors}",
    "org.opencontainers.image.licenses" = "Apache-2.0"
    "org.opencontainers.image.base.name" = "docker.io/library/ubuntu:${tag(base)}"
    "org.opencontainers.image.base.digest" = "${digest(base)}"
  }
}

function tag {
  params = [ imageNameWithSha ]
  result = index(split("@", index(split(":", imageNameWithSha), 1)), 0)
}

function distroVersion {
  params = [ imageNameWithSha ]
  result = index(split("-", tag(imageNameWithSha)), 0)
}

function digest {
  params = [ imageNameWithSha ]
  result = index(split("@", imageNameWithSha), 1)
}

function cleanVersion {
    params = [ version ]
    result = replace(version, "~", "")
}

function isPreview {
    params = [ version ]
    result = length(regexall("[0-9]+~(alpha|beta|rc).*", version)) > 0
}

function getMajor {
    params = [ version ]
    result = (isPreview(version) == true) ? index(split("~", version),0) : index(split(".", version),0)
}

function getExtensionsString {
    params = [ version, extensions ]
    result = (isPreview(version) == true) ? "" : join(" ", formatlist("postgresql-%s-%s", getMajor(version), extensions))
}

// This function conditionally adds recommended PostgreSQL packages based on
// the version. For example, starting with version 18, PGDG moved `jit` out of
// the main package and into a separate one.
function getStandardAdditionalPostgresPackagesPerMajorVersion {
    params = [ majorVersion ]
    // Add PostgreSQL jit package from version 18
    result = join(" ", [
      majorVersion < 18 ? "" : format("postgresql-%s-jit", majorVersion)
    ])
}

function isMajorPresent {
  params = [major, pgVersions]
  result = contains([for v in pgVersions : getMajor(v)], major)
}

function getPgVersions {
  params = [stableVersions, previewVersions]
  // Remove any preview version if already present as stable
  result = concat(stableVersions,
    [
      for v in previewVersions : v
      if !isMajorPresent(getMajor(v), stableVersions)
    ]
  )
}

function getRollingTags {
    params = [ imageName, pgVersion ]
    result = [
      format("%s:%s", imageName, pgVersion),
      format("%s:%s", imageName, getMajor(pgVersion))
    ]
}
