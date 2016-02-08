#!/bin/bash
#
# Based on https://github.com/antonblanchard/jenkins-scripts/blob/master/gcc_kernel_build.sh

#------
# DEBUG
#------

if grep -q debug <<< $@; then
  set -x
fi
set -o errexit
set -o pipefail
set -o nounset

#---------
# VARIABLES
#----------

# Defaults, can be overridden with env or args
BASEDIR="${BASEDIR:-${PWD}/gcc-build-$$}"
CLEAN="${CLEAN:-false}"
GIT_URL="${GIT_URL:-git://fs.ozlabs.ibm.com/mirror}"
INSTALL="${INSTALL:-false}"
JOBS="${JOBS:--j$(($(nproc) / 4))}"
GCC_REFERENCE="${REFERENCE:-}"
BINUTILS_REFERENCE="${REFERENCE:-}"
# No defaults for these two
TARGET="${TARGET:-}"
VERSION="${VERSION:-}"
# Used internally to know that we've successfully created BASEDIR
BASE=""

#----------
# FUNCTIONS
#----------

# Print usage and quit
usage() {
  cat << EOF
Usage: $0 --version <version> --target <target> [options]

Required args:
  --version <num>     version of GCC to build, e.g. 5.2.0
                      Can also be git tag or branch, we look for tags first
  --target <string>   gcc target to build, as supported by gcc
                      E.g., arm|aarch64|ppc|ppc64|ppc64le|sparc64|x86|x86_64

Options:
  --basedir <dir>     directory to use for build
  --clean             delete the build in basedir (consider using with --install)
  --debug             run with set -x
  --git <url>         URL of git mirror to use, default git://fs/mirror
  --install <dir>     install the build to specified dir (consider using with --clean)
  --jobs <num>        number of jobs to pass to make -j, will default to $(($(nproc) / 4))
  --reference <url>   parent dir for existing repo for clones, e.g. /var/lib/jenkins/git
  --help              show this help message

Short Options:
  -b <dir>            Same as --basedir <dir>
  -c                  Same as --clean
  -d                  Same as --debug
  -g <url>            Same as --git <url>
  -i <dir>            Same as --install <dir>
  -j <num>            Same as --jobs <num>
  -r <url>            Same as --ref <url>
  -h                  Same as --help

EOF
  exit 1
}

# Trap the EXIT call, clean up if required
finish() {
  if [[ "${CLEAN}" == "true" && "${BASE}" ]]; then
    echo "Cleaning up basedir in ${BASEDIR}"
    rm -rf "${BASEDIR:?}"/{install,src,build}
  elif [[ "${BASE}" ]]; then
    echo "Build dir still available under ${BASEDIR}"
  fi
}
trap finish EXIT

# Countdown to give user a chance to exit
countdown() {
  i=5
  while [[ "${i}" -ne 0 ]]; do
    sleep 1
    echo -n "${i}.. "
    i=$(( i - 1 ))
  done
  sleep 1
}

# Print summary of the build for the user
print_summary() {
  echo " * GCC ${VERSION} for ${NAME}"
  echo " * From ${branch} on ${GIT_URL}"
  if [[ "${INSTALL}" != "false" ]]; then
    echo -e " * Install to:\n\t${INSTALL}/gcc-${VERSION}-nolibc/${NAME}/"
  fi
  echo -n " * Build dir "
  if [[ "${CLEAN}" == "true" ]]; then
    echo -n "(to be cleaned) "
  fi
  echo -e "at: \n\t${BASEDIR}\n"
}

#------------------------
# PARSE COMMAND LINE ARGS
#------------------------

CMD_LINE=$(getopt -o b:cdg:hi:j:r:t:v: --longoptions basedir:,clean,debug,git:,help,install:,jobs:,reference:,target:,version: -n "$0" -- "$@")
eval set -- "${CMD_LINE}"

while true ; do
  case "${1}" in
    -b|--basedir)
      BASEDIR="${2}"
      shift 2
      ;;
    -c|--clean)
      CLEAN=true
      shift
      ;;
    -d|--debug)
      set -x
      shift
      ;;
    -g|--git)
      GIT_URL="${2}"
      shift 2
      ;;
    -i|--install)
      INSTALL="${2}"
      shift 2
      ;;
    -j|--jobs)
      JOBS="-j ${2}"
      shift 2
      ;;
    -r|--reference)
      GCC_REFERENCE="--reference ${2}/gcc.git"
      BINUTILS_REFERENCE="--reference ${2}/binutils-gdb.git"
      shift 2
      ;;
    -t|--target)
      TARGET="${2}"
      shift 2
      ;;
    -v|--version)
      VERSION="${2}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

#---------------
# TESTS & CHECKS
#---------------

# Make sure we have required args
if [[ -z "${VERSION}" || -z "${TARGET}" ]]; then
  usage
fi

# If builddir isn't a full-path, exit
if [[ "${BASEDIR:0:1}" != "/" ]]; then
  echo "Basedir is not a full path, using this instead:"
  echo -e "$(pwd)/${BASEDIR}\n"
  BASEDIR="$(pwd)/${BASEDIR}"
fi

# Work out the targets for GCC, if it's ppc or arm then we need to set the targets appropriately
case "${TARGET}" in
  "arm")
    TARGETS="--target=arm-linux-gnueabi --enable-targets=all"
    NAME="arm-linux"
    ;;
  "ppc")
    TARGETS="--target=powerpc-linux --enable-targets=all"
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
  *)
    TARGETS="--target=${TARGET}-linux --enable-targets=all"
    NAME="${TARGET}-linux"
    ;;
esac

# Test that we can talk to both git servers before continuing
[[ "$(git ls-remote --tags --heads "${GIT_URL}"/gcc.git 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact gcc git server" ; exit 1 )
[[ "$(git ls-remote --tags --heads "${GIT_URL}"/binutils-gdb.git 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact binutils git server" ; exit 1 )

# Get a list of all tags and branches from the specified git server
gitlist=($(git ls-remote --tags --heads "${GIT_URL}"/gcc.git 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))

# Error if we couldn't get tags or branches from git server
if [[ "${#gitlist[*]}" -eq 0 ]]; then
  # We didn't find anything
  echo "ERROR: Couldn't get anything from the git server at ${GIT_URL}"
  exit 1
fi

# Check if we have the version specified in either a tag or branch
# Tags follow format gcc-<version>-release, e.g. gcc-5_1_0-release
branch=""
for i in "${!gitlist[@]}"; do
  if [[ "${gitlist[i]}" == "gcc-${VERSION//\./_}-release" ]]; then
    branch="gcc-${VERSION//\./_}-release"
    break
  elif [[ "${gitlist[i]}" == "${VERSION}" ]]; then
    branch="${VERSION}"
    break
  fi
done

# Else we can't find what we're looking for
if [[ -z "${branch}" ]]; then
  echo "Could not find the version, ${VERSION}"
  exit 1
fi

# Warn if we will clean the build and not install it. Don't pause for answer, just let user cancel.
if [[ "${CLEAN}" == "true" && "${INSTALL}" == "false" ]]; then
  echo "WARNING: You want to clean the build and you're not installing it either."
  echo "Are you sure?"
  echo -e "\nContinuing in.."
  countdown
  echo -e "OK, continuing..\n"
fi

# Test if we can write to the install directory before we go to the trouble of building everything
if [[ "${INSTALL}" != "false" &&  ! -d "${INSTALL}" ]]; then
  echo "ERROR: Install dir doesn't seem to exist at ${INSTALL}"
  exit 1
elif [[ "${INSTALL}" != "false" &&  ! -w "${INSTALL}" ]]; then
  echo "ERROR: Can't write to install dir at ${INSTALL}"
  exit 1
fi

# Test and make our build directory
mkdir -p "${BASEDIR}" 2>/dev/null || ( echo "ERROR: Couldn't make the basedir at ${BASEDIR}" ; exit 1 )
BASE="true"
cd "${BASEDIR}"
rm -rf install src build
mkdir -p install src build/binutils build/gcc

# Print a summary of what we're going to try and do
echo "We're building:"
print_summary
echo -e "\n\"On my mark...\""
countdown
echo -e "\n\"Engage!\"\n"

#-------------
# DO THE BUILD
#-------------

# Clone the sources
echo "Cloning sources ..."
cd src

# We have a branch, so let's continue
git clone ${GCC_REFERENCE} -b "${branch}" --depth=10 -q "${GIT_URL}"/gcc.git 2>/dev/null || ( echo "Failed to clone gcc git repo, exiting." ; exit 1 ) && ( cd gcc; git --no-pager log -1 )

VERSION="$(< gcc/gcc/BASE-VER)"

# Get binutils
git clone ${BINUTILS_REFERENCE} -b binutils-2_25-branch --depth=10 -q "${GIT_URL}"/binutils-gdb.git || ( echo "Failed to clone binutils git repo, exiting." ; exit 1 ) && ( cd binutils-gdb; git --no-pager log -1 )

# Build binutils
echo "Building binutils ..."
cd "${BASEDIR}/build/binutils"
../../src/binutils-gdb/configure --disable-gdb --disable-libdecnumber --disable-readline --disable-sim --prefix="${BASEDIR}/install/${NAME}" ${TARGETS}

make -s ${JOBS}
make -s install

# Build gcc
echo "Building gcc ..."
cd "${BASEDIR}/build/gcc"
../../src/gcc/configure --prefix="${BASEDIR}/install/${NAME}" --disable-multilib --disable-bootstrap --enable-languages=c ${TARGETS}

# We don't need libgcc for building the kernel, so keep it simple
make -s all-gcc ${JOBS}
make -s install-gcc

# Install if specified
if [[ "${INSTALL}" != "false" ]]; then
  DESTDIR="${INSTALL}/gcc-${VERSION}-nolibc/${NAME}/"
  mkdir -p "${DESTDIR}" || ( echo "Error: can't write to install dir, ${DESTDIR}"; exit 1 )
  echo "Installing to ${DESTDIR}..."
  rsync -aH --delete "${BASEDIR}/install/${NAME}"/ "${DESTDIR}"
fi

# Print summary
echo "We built:"
print_summary

exit 0
