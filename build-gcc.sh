#!/bin/bash
#
# Based on https://github.com/antonblanchard/jenkins-scripts/blob/master/gcc_kernel_build.sh

BRANCH="${1}"
TARGET="${2}"
INSTALL="${3}"
NOCLEAN="${4}"
GIT_URL="git://fs.ozlabs.ibm.com/mirror"
BASEDIR="${PWD}/gcc-build-$$"
PARALLEL="-j$(($(nproc) / 4))"
OUTPUT="${OUTPUT:-/opt/cross/${USER}}"

if [[ -z "${BRANCH}" || -z "${TARGET}" ]]; then
  cat <<EOF
Usage: $0 <version> <target> [--install] [--noclean]

--version   tag or a branch from the GCC git tree
--target    as supported by GCC, e.g arm|aarch64|ppc|ppc64|ppc64le|sparc64
Note: "ppc" builds a gcc which supports both ppc64 and ppc64le
--install   copy to /opt/cross/${USER}/gcc-<version>-nolibc/
--noclean   keep the temporary build directory once complete

Example: $0 5.2.0 ppc64le --install
EOF
  exit 1
fi

set -o errexit
set -o pipefail
set -o nounset

# Trap the EXIT call and clean up, unless --noclean is passed as argument
function finish {
if [[ ! "${NOCLEAN}" ]]; then
  echo "Cleaning up..."
  rm -rf "${BASEDIR}"
else
  echo "Temporary build dir still available at ${BASEDIR}"
fi
}
trap finish EXIT


# Work out the targets for GCC
case "${TARGET}" in
  "aarch64")
    TARGETS="--target=aarch64-linux-gnueabi --enable-targets=all"
    NAME="aarch64-linux"
    ;;
  "arm")
    TARGETS="--target=arm-linux-gnueabi --enable-targets=all"
    NAME="arm-linux"
    ;;
  "ppc")
    TARGETS="--target=powerpc-linux --enable-targets=powerpc-linux,powerpc64-linux,powerpcle-linux,powerpc64le-linux"
    NAME="powerpc-linux"
    ;;
  "ppc64")
    TARGETS="--target=powerpc64-linux --enable-targets=powerpc-linux,powerpc64-linux"
    NAME="powerpc64-linux"
    ;;
  "ppc64le")
    TARGETS="--target=powerpc64le-linux --enable-targets=powerpcle-linux,powerpc64le-linux"
    NAME="powerpc64le-linux"
    ;;
  "sparc64")
    TARGETS="--target=sparc64-linux --enable-targets=all"
    NAME="sparc64-linux"
    ;;
  "x86_64")
    TARGETS="--target=x86_64-linux --enable-targets=all"
    NAME="x86_64-linux"
    ;;
  *)
    echo "I don't know what the target ${TARGET} is, sorry" ; exit 1
    ;;
esac

mkdir -p "${BASEDIR}"

rm -rf install src build

mkdir -p install src build/binutils build/gcc

# Check if we have the version specified in either a tag or branch
# Tags follow format gcc-<version>-release, e.g. gcc-5_1_0-release
egrep -q "${BRANCH//\./_}|gcc-${BRANCH//\./_}-release" <<< "$(git ls-remote --heads --tags ${GIT_URL}/gcc.git)" || ( echo "Could not find the version ${BRANCH}, sorry"; exit 1 )

# Test if we can write to the output directory
if [[ "${INSTALL}" == "--install" && ! -w "${OUTPUT}" ]]; then
  echo "Error: can't write to ${OUTPUT}, sorry" >&2
  exit 1
fi
# -----------------
# Clone the sources
# -----------------
echo "Cloning sources ..."
cd src

# Get GCC first to make sure we have a version available in tags
if [[ "${BRANCH}" != "master" && ! "${BRANCH}" =~ branch ]]; then
  branch="gcc-${BRANCH//\./_}-release"
else
  branch="${BRANCH}"
fi

git clone -b "${branch}" --depth=100 -q ${GIT_URL}/gcc.git 2>/dev/null || ( echo "Failed to clone git repo, exiting." ; exit 1 )
( cd gcc; git --no-pager log -1 )

VERSION="$(< gcc/gcc/BASE-VER)"

# Get binutils
git clone -b binutils-2_25-branch --depth=100 -q "${GIT_URL}/binutils-gdb.git"
( cd binutils-gdb; git log -1 )

# --------------
# Build binutils
# --------------
echo "Building binutils ..."
cd "${BASEDIR}/build/binutils"
../../src/binutils-gdb/configure --disable-gdb --disable-libdecnumber --disable-readline --disable-sim --prefix="${BASEDIR}/install/${NAME}" ${TARGETS}

make -s "${PARALLEL}"
make -s install

# ---------
# Build gcc
# ---------
echo "Building gcc ..."
cd "${BASEDIR}/build/gcc"

../../src/gcc/configure --prefix="${BASEDIR}/install/${NAME}" --disable-multilib --disable-bootstrap --enable-languages=c ${TARGETS}

# We don't need libgcc for building the kernel, so keep it simple
make -s all-gcc "${PARALLEL}"
make -s install-gcc

if [[ "${INSTALL}" == "--install" ]]; then
  DESTDIR="/opt/cross/${USER}/gcc-${VERSION}-nolibc/${NAME}/"
  mkdir -p "${DESTDIR}" || {
  echo "Error: can't write to ${DESTDIR}" >&2
  exit 1
}
  echo "Installing to /opt/cross ..."
  rsync -aH --delete "${BASEDIR}/install/${NAME}"/ "${DESTDIR}"
else
  if [[ "${NOCLEAN}" ]]; then
    echo "Not installing, compiler is in ${BASEDIR}/install"
  fi
  echo "Ahh, you didn't want me to install it and I'm cleaning up. I guess it built, at least."
fi

echo "=================================================="
echo " OK"
echo "=================================================="
exit 0
