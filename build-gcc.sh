#!/bin/bash
#
# Based on https://github.com/antonblanchard/jenkins-scripts/blob/master/gcc_kernel_build.sh

BRANCH=$1
ENDIAN=$2
INSTALL="${3}"
NOCLEAN="${4}"

if [[ -z "$BRANCH" || -z "$ENDIAN" ]]; then
	echo "Usage: $0 <version|head> <big|little|both> [--install] [--noclean]" >&2
	exit 1
fi

set -o errexit
set -o pipefail
set -o nounset

# Trap the EXIT call and clean up, unless --noclean is passed as argument
function finish {
  if [[ ! "${NOCLEAN}" ]]; then
    echo "Cleaning up..."
    rm -rf ${BASEDIR}
  else
    echo "OK, not cleaning up..."
  fi
}
trap finish EXIT

if [[ $ENDIAN == "big" ]]; then
	TARGETS="--target=powerpc64-linux --enable-targets=powerpc-linux,powerpc64-linux"
	NAME="powerpc64-linux"
elif [[ $ENDIAN == "little" ]]; then
	TARGETS="--target=powerpc64le-linux --enable-targets=powerpcle-linux,powerpc64le-linux"
	NAME="powerpc64le-linux"
else
	TARGETS="--target=powerpc-linux --enable-targets=powerpc-linux,powerpc64-linux,powerpcle-linux,powerpc64le-linux"
	NAME="powerpc-linux"
fi

BASEDIR=$PWD/gcc-build-$$
PARALLEL=-j$(nproc)

mkdir $BASEDIR
cd $BASEDIR

rm -rf install src build

mkdir -p install src build/binutils build/gcc

# -----------------
# Clone the sources
# -----------------
echo "Cloning sources ..."
cd src

# Get GCC first to make sure we have a version available in tags
if [[ "${BRANCH}" != "head" ]]; then
  branch="-b gcc-${BRANCH//\./_}-release"
fi

git clone $branch --depth=100 -q git://fs.ozlabs.ibm.com/mirror/gcc.git 2>/dev/null || (echo "Could not find version ${BRANCH}, sorry." ; exit 1)
(cd gcc; git log -1)

VERSION=$(< gcc/gcc/BASE-VER)

# Get binutils
git clone -b binutils-2_25-branch --depth=100 -q git://fs.ozlabs.ibm.com/mirror/binutils-gdb.git
(cd binutils-gdb; git log -1)

# --------------
# Build binutils
# --------------
echo "Building binutils ..."
cd $BASEDIR/build/binutils
../../src/binutils-gdb/configure --disable-gdb --disable-libdecnumber --disable-readline --disable-sim --prefix=$BASEDIR/install/$NAME $TARGETS

make -s $PARALLEL
make -s install

# ---------
# Build gcc
# ---------
echo "Building gcc ..."
cd $BASEDIR/build/gcc

../../src/gcc/configure --prefix=$BASEDIR/install/$NAME --disable-multilib --disable-bootstrap --enable-languages=c $TARGETS

# We don't need libgcc for building the kernel, so keep it simple
make -s all-gcc $PARALLEL
make -s install-gcc

if [[ "${INSTALL}" == "--install" ]]; then
	DESTDIR=/opt/cross/gcc-$VERSION-nolibc/$NAME/
	mkdir -p $DESTDIR || {
		echo "Error: can't write to $DESTDIR" >&2
		exit 1
	}

	echo "Installing to /opt/cross ..."
	rsync -a --delete $BASEDIR/install/$NAME/ $DESTDIR
else
	echo "Not installing, compiler is in $BASEDIR/install"
fi

echo "=================================================="
echo " OK"
echo "=================================================="
exit 0
