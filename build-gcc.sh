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
GIT_URL="${GIT_URL:-git://gitlab.ozlabs.ibm.com/mirror}"
GIT_URL_BINUTILS="${GIT_URL_BINUTILS:-}"
GIT_URL_GCC="${GIT_URL_GCC:-}"
INSTALL="${INSTALL:-false}"
JOBS="${JOBS:--j$(($(nproc) / 4))}"
LOCAL="${LOCAL:-}"
GCC_REFERENCE="${REFERENCE:-}"
BINUTILS_REFERENCE="${REFERENCE:-}"
BINUTILS_VERSION="${REFERENCE:-2.25}"
GLIBC="${GLIBC:-none}"
# No defaults for these
TARGET="${TARGET:-}"
ARCH_LINUX="${ARCH_LINUX:-}"
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
--version <num>		version of GCC to build, e.g. 5.2.0
- Can also be git tag or branch, we look for tags first
--target <string>	gcc target to build, as supported by gcc
- E.g., arm|aarch64|ppc|ppc64|ppc64le|sparc64|x86|x86_64

Options:
--basedir <dir>		directory to use for build
--binutils <url>	URL to binutils git repo, default git://gitlab/mirror/binutils-gdb.git
--binutils-ref <dir>	Directory to reference git repo for binutils
--binutils-ver <branch>	Use this branch for building binutils, defaults to 2.25
--clean			delete the build in basedir (consider using with --install)
--debug			run with set -x
--gcc <url>		URL to gcc git repository, default git://gitlab/mirror/gcc.git
--gcc-ref <dir>		Directory to reference git repo for gcc
--git <url>		URL of git mirror to use, default git://gitlab/mirror
--install <dir>		install the build to specified dir (consider using with --clean)
--jobs <num>		number of jobs to pass to make -j, will default to $(($(nproc) / 4))
--local			skips clone and uses gcc repos specified with --gcc and --binutils
--reference <dir>	parent dir for existing repo for clones, e.g. /var/lib/jenkins/git
--help			show this help message

Short Options:
-b <dir>		Same as --basedir <dir>
-c			Same as --clean
-d			Same as --debug
-g <url>		Same as --git <url>
-i <dir>		Same as --install <dir>
-j <num>		Same as --jobs <num>
-l			Same as --local
-r <url>		Same as --reference <dir>
-h			Same as --help

EOF
	exit 1
}

# Trap the EXIT call, clean up if required
finish() {
	if [[ "${CLEAN}" == "true" && "${BASE}" ]]; then
		echo "Cleaning up basedir in ${BASEDIR}"
		rm -rf "${BASEDIR:?}"/{install,src,build,version}
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

branch=
branch_binutils=

# Print summary of the build for the user
print_summary() {
	echo " * GCC ${VERSION} for ${NAME}"
	echo " * From ${branch} on ${GIT_URL_GCC}"
	echo " * Using binutils ${branch_binutils}"
	if [[ "${INSTALL}" != "false" ]]; then
		echo -e " * Install to:\n\t${DEST_DIR}"
	fi
	echo -n " * Build dir "
	if [[ "${CLEAN}" == "true" ]]; then
		echo -n "(to be cleaned) "
	fi
	echo -e "at: \n\t${BASEDIR}\n"
}

# Check that reference repositories are legitimate, else exit
check_reference() {
	if [[ ! -d "${1}" ]]; then
		echo "Reference directories must be a local directory."
		echo "${1} is invalid."
		exit 1
	fi
}

#------------------------
# PARSE COMMAND LINE ARGS
#------------------------

CMD_LINE=$(getopt -o b:cdg:hi:j:lr:t:v: --longoptions basedir:,binutils:,binutils-ref:,binutils-ver:,clean,debug,gcc:,gcc-ref:,git:,help,install:,jobs:,local,reference:,target:,version: -n "$0" -- "$@")
eval set -- "${CMD_LINE}"

while true ; do
	case "${1}" in
		-b|--basedir)
			BASEDIR="${2}"
			shift 2
			;;
		--binutils)
			GIT_URL_BINUTILS="${2}"
			shift 2
			;;
		--binutils-ref)
			if [[ -n "${BINUTILS_REFERENCE}" ]];then
				echo "--binutils-ref incompatible with --reference"
				exit 1
			fi
			check_reference "${2}"
			BINUTILS_REFERENCE="--reference ${2}"
			shift 2
			;;
		--binutils-ver)
			BINUTILS_VERSION="${2}"
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
		--gcc)
			GIT_URL_GCC="${2}"
			shift 2
			;;
		--gcc-ref)
			if [[ -n "${GCC_REFERENCE}" ]];then
				echo "--gcc-ref incompatible with --reference"
				exit 1
			fi
			check_reference "${2}"
			GCC_REFERENCE="--reference ${2}"
			shift 2
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
		-l|--local)
			LOCAL="true"
			shift
			;;
		-r|--reference)
			if [[ -n "${GCC_REFERENCE}" || -n "${BINUTILS_REFERENCE}" ]];then
				echo "--reference incompatible with --gcc-ref and --binutils-ref"
				exit 1
			fi
			check_reference "${2}"
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

# Set the default git urls if they weren't specified
if [[ -z "${GIT_URL_GCC}" ]];then
	GIT_URL_GCC="${GIT_URL}/gcc.git"
fi
if [[ -z "${GIT_URL_BINUTILS}" ]];then
	GIT_URL_BINUTILS="${GIT_URL}/binutils-gdb.git"
fi

# If local was set, make sure we have a legit directory
if [[ -n "${LOCAL}" ]]; then
	if [[ ! -d "${GIT_URL_GCC}" || ! -d "${GIT_URL_BINUTILS}" ]]; then
		echo "Git repos don't seem to be local directories."
		exit 1
	fi
fi

# Work out the targets for GCC
# ARM and PPC need to set the targets appropriately, else base on ${TARGET}
case "${TARGET}" in
	"arm")
		TARGETS="--target=arm-linux-gnueabi --enable-targets=all"
		NAME="arm-linux"
		ARCH_LINUX="arm"
		;;
	"ppc"|"powerpc")
		TARGETS="--target=powerpc-linux --enable-targets=all"
		NAME="powerpc-linux"
		ARCH_LINUX="powerpc"
		;;
	"ppc64"|"powerpc64")
		TARGETS="--target=powerpc64-linux --enable-targets=powerpc-linux,powerpc64-linux"
		NAME="powerpc64-linux"
		ARCH_LINUX="powerpc"
		;;
	"ppc64le"|"powerpc64le")
		TARGETS="--target=powerpc64le-linux --enable-targets=powerpcle-linux,powerpc64le-linux"
		NAME="powerpc64le-linux"
		ARCH_LINUX="powerpc"
		;;
	*)
		TARGETS="--target=${TARGET}-linux --enable-targets=all"
		NAME="${TARGET}-linux"
		ARCH_LINUX="${TARGET}"
		;;
esac

# Now that we have ${NAME}, set other variables for building 
SRC_DIR="${BASEDIR}/src"
BUILD_DIR="${BASEDIR}/build"
INSTALL_DIR="${BASEDIR}/install"
PREFIX="${INSTALL_DIR}/${NAME}"
SYSROOT="${PREFIX}/sysroot"
if [[ "${GLIBC}" == "none" ]]; then
	DEST_DIR="${INSTALL}/gcc-${VERSION}-nolibc/${NAME}/"
else
	DEST_DIR="${INSTALL}/gcc-${VERSION}-libc-${GLIBC}/${NAME}/"
fi

## Test that we can talk to both git servers before continuing
#[[ "$(git ls-remote --tags --heads "${GIT_URL_GCC}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact gcc git server" ; exit 1 )
#[[ "$(git ls-remote --tags --heads "${GIT_URL_BINUTILS}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact binutils git server" ; exit 1 )
#
## Get a list of all tags and branches from the specified git server
#gitlist=($(git ls-remote --tags --heads "${GIT_URL_GCC}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))
#
## Error if we couldn't get tags or branches from git server
#if [[ "${#gitlist[*]}" -eq 0 ]]; then
#	# We didn't find anything
#	echo "ERROR: Couldn't get anything from the git server at ${GIT_URL_GCC}"
#	exit 1
#fi
#
# Check if we have the version specified in either a tag or branch
# Tags follow format gcc-<version>-release, e.g. gcc-5_1_0-release
#
#branch=""
#for i in "${!gitlist[@]}"; do
#	# check for tags first
#	if [[ "${gitlist[i]}" == "gcc-${VERSION//\./_}-release" ]]; then
#		branch="gcc-${VERSION//\./_}-release"
#		break
#		# check for branches next
#	elif [[ "${gitlist[i]}" == "${VERSION}" ]]; then
#		branch="${VERSION}"
#		break
#		# if local then HEAD, else master
#	elif [[ "${VERSION}" == "HEAD" ]]; then
#		if [[ -n "${LOCAL}" ]]; then
#			branch="${VERSION}"
#			break
#		else
#			branch="master"
#			break
#		fi
#	fi
#done
#
## Else we can't find what we're looking for
#if [[ -z "${branch}" ]]; then
#	echo "Could not find the version, ${VERSION}"
#	if [[ "${GIT_URL_GCC:0:1}" == "/" || "${GIT_URL_GCC:0:1}" == "~" ]]; then
#		echo "If this is a local repo, you might not have that branch."
#		echo "Try checking out the branch or use a tag."
#	fi
#	exit 1
#fi
#
## Work out which binutils branch to use
#branch_binutils=""
#if [[ "${BINUTILS_VERSION}" == "master" ]]; then
#	branch_binutils="master"
#elif [[ "${BINUTILS_VERSION}" == "HEAD" ]]; then
#	if [[ -n "${LOCAL}" ]]; then
#		branch_binutils="${BINUTILS_VERSION}"
#	else
#		branch_binutils="master"
#	fi
#else
#	# Look on binutils git repo
#	gitlist=($(git ls-remote --heads "${GIT_URL_BINUTILS}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))
#	for i in "${!gitlist[@]}"; do
#		if [[ "${gitlist[i]}" == "binutils-${BINUTILS_VERSION//\./_}-branch" ]]; then
#			branch_binutils="binutils-${BINUTILS_VERSION//\./_}-branch"
#			break
#		fi
#	done
#fi
#
#[[ ! "${branch_binutils}" ]] && { echo "Can't find a branch with binutils ${BINUTILS_VERSION}" ; exit 1 ; }

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
echo -e "\nWe're building:\n"
print_summary
echo -e "\n\"On my mark...\""
countdown
echo -e "\n\"Engage!\"\n"

#-------------
# DO THE BUILD
#-------------

# Clone the sources
cd "${SRC_DIR}"

#if [[ -n "${LOCAL}" ]]; then
#	echo "Linking existing sources..."
#	ln -s "${GIT_URL_GCC}" gcc || { echo "Failed to link to existing gcc repo at ${GIT_URL_GCC}" ; exit 1 ; }
#	ln -s "${GIT_URL_BINUTILS}" binutils-gdb || { echo "Failed to link to existing binutils repo at ${GIT_URL_BINUTILS}" ; exit 1 ; }
#else
#	echo "Cloning sources..."
#	# We have a branch, so let's continue
#	git clone ${GCC_REFERENCE} -b "${branch}" --depth=1 -q "${GIT_URL_GCC}" 2>/dev/null || { echo "Failed to clone gcc git repo, exiting." ; exit 1 ; } && ( cd gcc; echo -e "\nLatest GCC commit:\n" ; git --no-pager log -1)
#	# Get binutils
#	git clone ${BINUTILS_REFERENCE} -b "${branch_binutils}" --depth=1 -q "${GIT_URL_BINUTILS}" || { echo "Failed to clone binutils git repo, exiting." ; exit 1 ; } && ( cd binutils-gdb; echo -e "\nLatest binutils commit:\n" ; git --no-pager log -1 )
#fi


if [[ "${GLIBC}" != "none" ]]; then
	echo "Getting dependencies for glibc..."
	# Get deps for libc
	cd "${SRC_DIR}"

	# gcc
	mkdir gcc
	wget http://mirror.aarnet.edu.au/pub/gnu/gcc/gcc-5.3.0/gcc-5.3.0.tar.gz && \
		tar -xf gcc-5.3.0.tar.gz -C gcc --strip-components 1
	#Get version of GCC, according to the repo
	VERSION="$(< "${SRC_DIR}/gcc/gcc/BASE-VER")"

	# binutils
	mkdir binutils-gdb
	wget http://mirror.aarnet.edu.au/pub/gnu/binutils/binutils-2.26.tar.gz && \
		tar -xf binutils-2.26.tar.gz -C binutils-gdb --strip-components 1

	# Linux
	mkdir linux
	wget https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.5.tar.xz && \
		tar -xf linux-4.5.tar.xz -C linux  --strip-components 1

	# glibc
	mkdir glibc
	wget http://mirror.aarnet.edu.au/pub/gnu/glibc/glibc-2.23.tar.gz && \
		tar -xf glibc-2.23.tar.gz -C glibc --strip-components 1

	# mpfr
	mkdir mpfr
	wget http://ftpmirror.gnu.org/mpfr/mpfr-3.1.4.tar.bz2 && \
		tar -xf mpfr-3.1.4.tar.bz2 -C mpfr --strip-components 1

	# mpc
	mkdir mpc
	wget http://ftpmirror.gnu.org/mpc/mpc-1.0.3.tar.gz && \
		tar -xf mpc-1.0.3.tar.gz -C mpc --strip-components 1

	# gmp
	mkdir gmp
	wget http://ftpmirror.gnu.org/gmp/gmp-6.1.0.tar.bz2 && \
		tar -xf gmp-6.1.0.tar.bz2 -C gmp --strip-components 1

	# isl
	mkdir isl
	wget ftp://gcc.gnu.org/pub/gcc/infrastructure/isl-0.16.1.tar.bz2 && \
		tar -xf isl-0.16.1.tar.bz2  -C isl --strip-components 1

	#cloog
	mkdir cloog
	wget ftp://gcc.gnu.org/pub/gcc/infrastructure/cloog-0.18.1.tar.gz && \
		tar -xf cloog-0.18.1.tar.gz -C cloog --strip-components 1

	# Link gcc to deps
	cd "${SRC_DIR}/gcc"
	for x in cloog gmp isl mpc mpfr; do
		ln -s ../${x}
	done
fi

# Linux headers
if [[ "${GLIBC}" != "none" ]];
then
	# Install Linux headers
	echo -e "\nInstalling Linux headers ..."
	cd "${SRC_DIR}/linux"
	make ARCH="${ARCH_LINUX}" INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
else
	mkdir -p ${SYSROOT}
fi

# Build binutils
echo -e "\nBuilding binutils ..."
mkdir -p "${BUILD_DIR}/binutils" && cd "${BUILD_DIR}/binutils"
../../src/binutils-gdb/configure --prefix="${PREFIX}" ${TARGETS} --with-sysroot=${SYSROOT}

make -s ${JOBS} && make -s install

# Build GCC
echo -e "\nBuilding gcc ..."
mkdir -p "${BUILD_DIR}/gcc" && cd "${BUILD_DIR}/gcc"
../../src/gcc/configure --prefix="${PREFIX}" ${TARGETS} --enable-languages=c,c++ --disable-bootstrap --disable-multilib --with-long-double-128 --with-sysroot="${SYSROOT}"
make -s gcc_cv_libc_provides_ssp=yes all-gcc ${JOBS} && make -s install-gcc

# Write gcc and binutils version and git hash to file
#cat > "${BASEDIR}/version" << EOF
#GCC_VERSION=${VERSION}
#GCC_SHA1=${GCC_SHA1}
#BINUTILS_VERSION=${BINUTILS_VERSION}
#BINUTILS_SHA1=${BINUTILS_SHA1}
#EOF

if [[ "${GLIBC}" != "none" ]];
then
	# Now that we have a basic GCC and binutils, we can cross compile the rest
	export CROSS_COMPILE="${NAME}-"
	export PATH="${PREFIX}/bin/:${PATH}"

	# Install glibc headers
	mkdir -p "${BUILD_DIR}/glibc" && cd "${BUILD_DIR}/glibc"
	../../src/glibc/configure --prefix=/usr --build="${MACHTYPE}" --host="${NAME}" --target="${NAME}" --with-headers="${SYSROOT}/usr/include" --disable-multilib --enable-obsolete-rpc libc_cv_forced_unwind=yes
	make install-bootstrap-headers=yes install_root="${SYSROOT}" install-headers

	# Build crt, required for next stage GCC
	make ${JOBS} csu/subdir_lib
	mkdir -p "${SYSROOT}/usr/lib"
	install csu/crt1.o csu/crti.o csu/crtn.o "${SYSROOT}/usr/lib"

	# Next stage GCC requires libc.so and stubs.h to exist
	${NAME}-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o "${SYSROOT}/usr/lib/libc.so"
	mkdir -p "${SYSROOT}/usr/include/gnu"
	touch "${SYSROOT}/usr/include/gnu/stubs.h"

	# Build libgcc
	cd "${BUILD_DIR}/gcc"
	make ${JOBS} all-target-libgcc && make install-target-libgcc

	# Build glibc
	cd "${BUILD_DIR}/glibc"
	make ${JOBS} && make install_root="${SYSROOT}" install

	# Rebuild binutils with new native compiler
	#mkdir -p "${BUILD_DIR}/binutils-stage2" && cd "${BUILD_DIR}/binutils-stage2"
	#../../src/binutils-gdb/configure --prefix="${PREFIX}" ${TARGETS} --with-sysroot="${SYSROOT}"
	#make -s ${JOBS} && make -s install

	# Rebuild GCC with new native compiler
	#mkdir -p "${BUILD_DIR}/gcc-stage2" && cd "${BUILD_DIR}/gcc-stage2"
	#../../src/gcc/configure --prefix="${PREFIX}" ${TARGETS} --enable-languages=c,c++ --disable-multilib --with-long-double-128 --with-sysroot="${SYSROOT}"
	cd "${BUILD_DIR}/gcc"
	make gcc_cv_libc_provides_ssp=yes ${JOBS} && make install
fi

# Install if specified
if [[ "${INSTALL}" != "false" ]]; then
	mkdir -p "${DEST_DIR}" || { echo "Error: can't write to install dir, ${DEST_DIR}" ; exit 1 ; }
	echo "Installing to ${DEST_DIR}..."
	rsync -aH --delete "${INSTALL_DIR}/${NAME}"/ "${DEST_DIR}"
	cp "${BASEDIR}/version" "${DEST_DIR}/version"
fi

# Print summary
echo "We built:"
print_summary
