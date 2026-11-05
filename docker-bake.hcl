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

// PostgreSQL edition: "" builds the community images from apt.postgresql.org,
// "ee" builds CYBERTEC PostgreSQL Enterprise Edition images with TDE. See PGEE.md.
variable "pgEdition" {
  default = ""
}

// Extra APT repository, passed to the build as BuildKit secrets (never stored
// in the image). Required for pgEdition=ee. Paths to local files:
//   aptSources  deb822 .sources file; @VERSION_CODENAME@ is replaced by the distro
//   aptAuth     apt auth.conf with the repository credentials (optional)
//   aptKeyring  ASCII-armoured signing key, referenced in aptSources as
//               Signed-By: /etc/apt/keyrings/custom.asc (optional)
variable "aptSources" {
  default = ""
}
variable "aptAuth" {
  default = ""
}
variable "aptKeyring" {
  default = ""
}

// Prepended to the base image, e.g. "registry.example.com/dockerhub/", to pull
// it through a registry mirror.
variable "baseImagePrefix" {
  default = ""
}

// HTTP proxy for apt/pip inside the build. Unset values are not passed, so a
// proxy configured in ~/.docker/config.json keeps working.
variable "httpProxy" {
  default = ""
}
variable "httpsProxy" {
  default = ""
}
variable "noProxy" {
  default = ""
}

imageName = pgEdition == "" ? "postgresql" : "postgresql-${pgEdition}"
fullname = ( environment == "testing") ? "${registry}/${imageName}-testing" : "${registry}/${imageName}"
now = timestamp()
authors = "The CloudNativePG Contributors"
url = "https://github.com/cloudnative-pg/postgres-containers"

// PostgreSQL versions to build
postgreSQLVersions = [
  "14.24",
  "15.19",
  "16.15",
  "17.11",
  "18.6"
]

// PostgreSQL preview versions to build, such as "18~beta1" or "18~rc1"
// Preview versions are automatically filtered out if present in the stable list
// MANUALLY EDIT THE CONTENT - AND UPDATE THE README.md FILE TOO
postgreSQLPreviewVersions = [
  "19~rc1",
]

// CYBERTEC PGEE versions to build when pgEdition = "ee". They follow the
// CYBERTEC repository, not postgreSQLVersions above. A version is matched as
// "postgresql-NNee=<version>*", so "17.11" picks the latest 17.11eeX.Y.Z build.
pgeeVersions = [
  "17.11",
  "18.6"
]

// Barman version to build
// renovate: datasource=pypi versioning=loose depName=barman
barmanVersion = "3.20.1"

// Extensions to be included in the `standard` image
extensions = [
  "pgaudit",
  "pgvector",
  "pg-failover-slots"
]

target "default" {
  matrix = {
    // PGEE images skip the deprecated "system" type (Barman Cloud from PyPI)
    tgt = [for t in [
      "minimal",
      "standard",
      "system"
    ] : t if pgEdition == "" || t != "system"]
    // Get the list of PostgreSQL versions, filtering preview versions if already stable
    pgVersion = pgEdition == "" ? getPgVersions(postgreSQLVersions, postgreSQLPreviewVersions) : pgeeVersions
    base = [
      // renovate: datasource=docker versioning=loose
      "debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4",
      // renovate: datasource=docker versioning=loose
      "debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3"
    ]
  }
  platforms = [
    "linux/amd64",
    "linux/arm64"
  ]
  dockerfile = "Dockerfile"
  name = "postgresql-${index(split(".",cleanVersion(pgVersion)),0)}-${tgt}-${distroVersion(base)}"
  tags = [
    "${fullname}:${index(split(".",cleanVersion(pgVersion)),0)}-${tgt}-${distroVersion(base)}",
    "${fullname}:${cleanVersion(pgVersion)}-${tgt}-${distroVersion(base)}",
    "${fullname}:${cleanVersion(pgVersion)}-${formatdate("YYYYMMDDhhmm", now)}-${tgt}-${distroVersion(base)}",
  ]
  context = "."
  target = "${tgt}"
  args = merge({
    PG_VERSION = "${pgVersion}"
    PG_MAJOR = "${getMajor(pgVersion)}"
    BASE = "${baseImagePrefix}${base}"
    EXTENSIONS = "${getExtensionsString(pgVersion, extensions)}"
    STANDARD_ADDITIONAL_POSTGRES_PACKAGES = "${getStandardAdditionalPostgresPackagesPerMajorVersion(getMajor(pgVersion))}"
    BARMAN_VERSION = "${barmanVersion}"
    PG_EDITION = "${pgEdition}"
  },
  httpProxy == "" ? {} : { http_proxy = httpProxy, HTTP_PROXY = httpProxy },
  httpsProxy == "" ? {} : { https_proxy = httpsProxy, HTTPS_PROXY = httpsProxy },
  noProxy == "" ? {} : { no_proxy = noProxy, NO_PROXY = noProxy })
  secret = compact([
    aptSources == "" ? "" : "id=apt_sources,src=${aptSources}",
    aptAuth == "" ? "" : "id=apt_auth,src=${aptAuth}",
    aptKeyring == "" ? "" : "id=apt_keyring,src=${aptKeyring}",
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
    "index,manifest:org.opencontainers.image.base.name=docker.io/library/debian:${tag(base)}",
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
    "org.opencontainers.image.base.name" = "docker.io/library/debian:${tag(base)}"
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
      majorVersion < 18 ? "" : format("postgresql-%s%s-jit", majorVersion, pgEdition)
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
