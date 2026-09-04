#!/usr/bin/env bash
# Install Crystal 1.21.x on GitHub Ubuntu 26.04 / 26.04-arm.
# Ubuntu 26.04 dropped PCRE1. crystal-lang/install-crystal@v1 still asks apt
# for that PCRE1 package on those images. Crystal 1.21 needs PCRE2.
#
# 22.04 / 24.04 keep crystal-lang/install-crystal@v1 (YAML if).
# macOS jobs keep that action too. This script refuses non-Linux and
# Ubuntu other than 26.04 so Linux CI cannot mix the two install paths.
#
# Writes cryomongo/tmp/crystal/ (gitignored). Does not write /usr/bin/crystal.
# GitHub: appends tmp/crystal/bin to GITHUB_PATH for later steps.
#
# Official assets (2026-09-04, github.com/crystal-lang/crystal 1.21.0):
#   crystal-1.21.0-1-linux-x86_64.tar.gz
#   crystal-1.21.0-1-linux-aarch64.tar.gz
# Prefer non-bundled (matches the apt list below). Do not use *-bundled.tar.gz.
#
# Apt (PCRE2 only; never the PCRE1 -dev package):
#   libevent-dev libgmp-dev libssl-dev libxml2-dev libyaml-dev libpcre2-dev
#
# Usage:
#   scripts/ci-install-crystal.sh
#   FORCE=1 scripts/ci-install-crystal.sh
#   INSTALL_DEPS=1 scripts/ci-install-crystal.sh   # apt even outside Actions
# Local proof: omit INSTALL_DEPS so this host's packages stay as they are.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${ROOT}/tmp"
OUT="${CRYSTAL_PREFIX:-${ROOT}/tmp/crystal}"
VERSION="${CRYSTAL_VERSION:-1.21.0}"
PKG_REV="${CRYSTAL_PKG_REV:-1}"

os="$(uname -s 2>/dev/null || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"

if [[ "$os" != "Linux" ]]; then
  echo "scripts/ci-install-crystal.sh is for GitHub Ubuntu 26.04 / 26.04-arm." >&2
  echo "macOS CI uses crystal-lang/install-crystal@v1." >&2
  echo "Windows GitHub is leftover (the driver does not compile)." >&2
  exit 1
fi

os_id=""
os_ver=""
if [[ -f /etc/os-release ]]; then
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  os_ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
fi
if [[ "$os_id" != "ubuntu" || "$os_ver" != "26.04" ]]; then
  echo "scripts/ci-install-crystal.sh is for Ubuntu 26.04 only (got ${os_id:-unknown} ${os_ver:-unknown})." >&2
  echo "22.04 / 24.04 keep crystal-lang/install-crystal@v1." >&2
  exit 1
fi

# Pin the 1.21 series (same as install-crystal@v1 crystal: latest on 2026-09-04).
if [[ ! "$VERSION" =~ ^1\.21\.[0-9]+$ ]]; then
  echo "Pin Crystal 1.21.x (got ${VERSION})." >&2
  exit 1
fi

case "$OUT" in
  /usr | /usr/bin | /usr/local | /usr/local/bin)
    echo "Refusing to replace system Crystal at ${OUT}." >&2
    exit 1
    ;;
esac

# uname -m on GitHub: x86_64 or aarch64. runner.arch is X64 / ARM64 — do not use that.
tarball_arch=""
case "$arch" in
  x86_64 | amd64)
    tarball_arch="x86_64"
    ;;
  aarch64 | arm64)
    tarball_arch="aarch64"
    ;;
  *)
    echo "No official Crystal ${VERSION} Linux tarball for arch ${arch}." >&2
    exit 1
    ;;
esac

# Non-bundled name only. A -bundled suffix would skip the apt PCRE2 packages.
ASSET="crystal-${VERSION}-${PKG_REV}-linux-${tarball_arch}.tar.gz"
URL="${CRYSTAL_DOWNLOAD_URL:-https://github.com/crystal-lang/crystal/releases/download/${VERSION}/${ASSET}}"

install_apt_deps() {
  # Same list as install-crystal@v1 for Crystal >= 1.8, with PCRE2 instead of PCRE1.
  local packages=(
    libevent-dev
    libgmp-dev
    libssl-dev
    libxml2-dev
    libyaml-dev
    libpcre2-dev
  )
  echo "Installing Crystal apt packages (PCRE2): ${packages[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends -- "${packages[@]}"
}

have_crystal() {
  [[ -x "${OUT}/bin/crystal" && -x "${OUT}/bin/shards" &&
    -f "${OUT}/VERSION" && "$(cat "${OUT}/VERSION")" == "$VERSION" ]]
}

put_crystal_on_path() {
  # Later GitHub steps read GITHUB_PATH. This process uses PATH for --version.
  export PATH="${OUT}/bin:${PATH}"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${OUT}/bin" >> "$GITHUB_PATH"
  fi
}

if [[ "${GITHUB_ACTIONS:-}" == "true" || "${INSTALL_DEPS:-}" == "1" ]]; then
  install_apt_deps
else
  echo "Skipping apt (set INSTALL_DEPS=1 or run in GitHub Actions)."
fi

if [[ "${FORCE:-}" != "1" ]] && have_crystal; then
  put_crystal_on_path
  echo "CRYSTAL_BIN=${OUT}/bin"
  "${OUT}/bin/crystal" --version
  exit 0
fi

mkdir -p "$CACHE"
tarball="${CACHE}/${ASSET}"
if [[ "${FORCE:-}" == "1" || ! -f "$tarball" ]]; then
  echo "Downloading Crystal ${VERSION} (${ASSET})"
  echo "URL: ${URL}"
  curl -fL --retry 5 --retry-all-errors --max-time 300 -o "${tarball}.partial" "$URL"
  mv "${tarball}.partial" "$tarball"
fi

tmp_dir="$(mktemp -d "${CACHE}/crystal-dl.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

tar zxf "$tarball" -C "$tmp_dir"

# Official tarball has one top-level directory (crystal-1.21.0-1).
inner=""
for d in "$tmp_dir"/*; do
  if [[ -d "$d" ]]; then
    if [[ -n "$inner" ]]; then
      echo "Crystal archive has more than one top-level directory" >&2
      find "$tmp_dir" -maxdepth 2 | head >&2 || true
      exit 1
    fi
    inner="$d"
  fi
done
if [[ -z "$inner" || ! -x "${inner}/bin/crystal" ]]; then
  echo "Crystal archive has no bin/crystal" >&2
  find "$tmp_dir" -type f | head >&2 || true
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$inner" "$OUT"

# install-crystal@v1 also links src -> share/crystal/src. Keep that layout.
if [[ -d "${OUT}/share/crystal/src" && ! -e "${OUT}/src" ]]; then
  ln -s share/crystal/src "${OUT}/src"
fi

printf '%s\n' "$VERSION" > "${OUT}/VERSION"
chmod a+x "${OUT}/bin/crystal"
if [[ -e "${OUT}/bin/shards" ]]; then
  chmod a+x "${OUT}/bin/shards"
fi

put_crystal_on_path
echo "CRYSTAL_BIN=${OUT}/bin"
"${OUT}/bin/crystal" --version
if [[ -x "${OUT}/bin/shards" ]]; then
  "${OUT}/bin/shards" --version
fi
