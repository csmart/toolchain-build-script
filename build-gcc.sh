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
BASEDIR="${BASEDIR:-${PWD}/gcc-build-$(date +%s)}"
CLEAN="${CLEAN:-false}"
INSTALL="${INSTALL:-false}"
JOBS="${JOBS:--j$(($(nproc) / 4))}"
LOCAL="${LOCAL:-}"
BASE_GIT_URL="${BASE_GIT_URL:-git://gitlab.ozlabs.ibm.com/mirror}"
GCC_GIT_URL="${GCC_GIT_URL:-}"
GCC_REFERENCE="${GCC_REFERENCE:-}"
GCC_VERSION="${GCC_VERSION:-}"
GCC_BRANCH="${GCC_BRANCH:-}"
BINUTILS_GIT_URL="${BINUTILS_GIT_URL:-}"
BINUTILS_REFERENCE="${BINUTILS_REFERENCE:-}"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.25}"
BINUTILS_BRANCH="${BINUTILS_BRANCH:-}"
GLIBC_GIT_URL="${GLIBC_GIT_URL:-}"
GLIBC_REFERENCE="${GLIBC_REFERENCE:-}"
GLIBC_VERSION="${GLIBC_VERSION:-}"
GLIBC_BRANCH="${GLIBC_BRANCH:-}"
# No defaults for these
TARGET="${TARGET:-}"
ARCH_LINUX="${ARCH_LINUX:-}"

#----------
# FUNCTIONS
#----------

# Print usage and quit
usage() {
	cat << EOF
Usage: $0 --version <version> --target <target> [options]

Required args:
--gcc <version>		version of GCC to build, e.g. 5.2.0
			- Can also be git tag or branch, we look for tags first
--target <string>	gcc target to build, as supported by gcc
			- E.g., arm|aarch64|ppc|ppc64|ppc64le|sparc64|x86|x86_64

Options:
--basedir <dir>		directory to use for build
--binutils-url <url>	URL to binutils git repo, default git://gitlab/mirror/binutils-gdb.git
--binutils-ref <dir>	Directory to reference git repo for binutils
--binutils <version>	Use this branch for building binutils, defaults to 2.25
--clean			delete the build in basedir (consider using with --install)
--debug			run with set -x
--gcc <version>		URL to gcc git repository, default git://gitlab/mirror/gcc.git
--gcc-ref <dir>		Directory to reference git repo for gcc
--git-url <url>		URL of git mirror to use, default git://gitlab/mirror
--install <dir>		install the build to specified dir (consider using with --clean)
--jobs <num>		number of jobs to pass to make -j, will default to $(($(nproc) / 4))
--local			skips clone and uses gcc repos specified with --gcc and --binutils
--reference <dir>	parent dir for existing repo for clones, e.g. /var/lib/jenkins/git
--help			show this help message

Short Options:
-b <dir>		Same as --basedir <dir>
-c			Same as --clean
-d			Same as --debug
-g <version>		Same as --git <version>
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
	if [[ "${CLEAN}" == "true" ]]; then
		echo "Cleaning up basedir in ${BASEDIR}"
		[[ -d "${BASEDIR:?}/build" ]] && rm -rf "${BASEDIR:?}build"
		[[ -d "${BASEDIR:?}/install" ]] && rm -rf "${BASEDIR:?}/install"
		[[ -d "${BASEDIR:?}/src" ]] && rm -rf "${BASEDIR:?}/src"
		[[ -e "${BASEDIR:?}/version" ]] && rm -f "${BASEDIR:?}/version"
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
	echo " * GCC ${GCC_VERSION} for ${NAME}"
	echo " * From ${GCC_BRANCH} on ${GCC_GIT_URL}"
	echo " * Using binutils ${BINUTILS_BRANCH}"
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

CMD_LINE=$(getopt -o b:cdg:hi:j:lr:t:v: --longoptions basedir:,binutils:,binutils-ref:,binutils-url:,clean,debug,gcc:,gcc-ref:,gcc-url,glibc:,glibc-ref:,glibc-url,git:,help,install:,jobs:,local,reference:,target:,version: -n "$0" -- "$@")
eval set -- "${CMD_LINE}"

while true ; do
	case "${1}" in
		-b|--basedir)
			BASEDIR="${2}"
			shift 2
			;;
		--binutils)
			BINUTILS_VERSION="${2}"
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
		--binutils-url)
			BINUTILS_GIT_URL="${2}"
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
			GCC_VERSION="${2}"
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
		--gcc-url)
			GCC_GIT_URL="${2}"
			shift 2
			;;
		--glibc)
			GLIBC_VERSION="${2}"
			shift 2
			;;
		--glibc-ref)
			if [[ -n "${GLIBC_REFERENCE}" ]];then
				echo "--glibc-ref incompatible with --reference"
				exit 1
			fi
			check_reference "${2}"
			GLIBC_REFERENCE="--reference ${2}"
			shift 2
			;;
		--glibc-url)
			GLIBC_GIT_URL="${2}"
			shift 2
			;;
		-g|--git)
			BASE_GIT_URL="${2}"
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
			if [[ -n "${GCC_REFERENCE}" || -n "${GLIBC_REFERENCE}" || -n "${BINUTILS_REFERENCE}" ]];then
				echo "--reference incompatible with other --ref options, e.g. --gcc-ref"
				exit 1
			fi
			check_reference "${2}"
			GCC_REFERENCE="--reference ${2}/gcc.git"
			GLIBC_REFERENCE="--reference ${2}/glibc.git"
			BINUTILS_REFERENCE="--reference ${2}/binutils-gdb.git"
			shift 2
			;;
		-t|--target)
			TARGET="${2}"
			shift 2
			;;
		--version|-v)
			GCC_VERSION="${2}"
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
if [[ -z "${GCC_VERSION}" || -z "${TARGET}" ]]; then
	usage
fi

# If builddir isn't a full-path, exit
if [[ "${BASEDIR:0:1}" != "/" ]]; then
	echo "Basedir is not a full path, using this instead:"
	echo -e "$(pwd)/${BASEDIR}\n"
	BASEDIR="$(pwd)/${BASEDIR}"
fi

# Set the default git urls if they weren't specified
if [[ -z "${GCC_GIT_URL}" ]];then
	GCC_GIT_URL="${BASE_GIT_URL}/gcc.git"
fi
if [[ -z "${BINUTILS_GIT_URL}" ]];then
	BINUTILS_GIT_URL="${BASE_GIT_URL}/binutils-gdb.git"
fi

# If local was set, make sure we have a legit directory
if [[ -n "${LOCAL}" ]]; then
	if [[ ! -d "${GCC_GIT_URL}" || ! -d "${BINUTILS_GIT_URL}" ]]; then
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
if [[ "${GLIBC_VERSION}" == "" ]]; then
	DEST_DIR="${INSTALL}/gcc-${GCC_VERSION}-nolibc/${NAME}/"
else
	DEST_DIR="${INSTALL}/gcc-${GCC_VERSION}-libc-${GLIBC_VERSION}/${NAME}/"
fi

# Test that we can talk to both git servers before continuing
[[ "$(git ls-remote --tags --heads "${GCC_GIT_URL}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact gcc git server" ; exit 1 )
[[ "$(git ls-remote --tags --heads "${BINUTILS_GIT_URL}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact binutils git server" ; exit 1 )

# Get a list of all tags and branches from the specified git server
gitlist=($(git ls-remote --tags --heads "${GCC_GIT_URL}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))

# Error if we couldn't get tags or branches from git server
if [[ "${#gitlist[*]}" -eq 0 ]]; then
	# We didn't find anything
	echo "ERROR: Couldn't get anything from the git server at ${GCC_GIT_URL}"
	exit 1
fi

# Check if we have the version specified in either a tag or branch
# Tags follow format gcc-<version>-release, e.g. gcc-5_1_0-release
for i in "${!gitlist[@]}"; do
	# check for tags first
	if [[ "${gitlist[i]}" == "gcc-${GCC_VERSION//\./_}-release" ]]; then
		GCC_BRANCH="gcc-${GCC_VERSION//\./_}-release"
		break
		# check for branches next
	elif [[ "${gitlist[i]}" == "${GCC_VERSION}" ]]; then
		GCC_BRANCH="${GCC_VERSION}"
		break
		# if local then HEAD, else master
	elif [[ "${GCC_VERSION}" == "HEAD" ]]; then
		if [[ -n "${LOCAL}" ]]; then
			GCC_BRANCH="${GCC_VERSION}"
			break
		else
			GCC_BRANCH="master"
			break
		fi
	fi
done

# Else we can't find what we're looking for
if [[ -z "${GCC_BRANCH}" ]]; then
	echo "Could not find the version, ${GCC_VERSION}"
	if [[ "${GIT_URL_GCC:0:1}" == "/" || "${GIT_URL_GCC:0:1}" == "~" ]]; then
		echo "If this is a local repo, you might not have that branch."
		echo "Try checking out the branch or use a tag."
	fi
	exit 1
fi

# Work out which binutils branch to use
if [[ "${BINUTILS_VERSION}" == "master" ]]; then
	BINUTILS_BRANCH="master"
elif [[ "${BINUTILS_VERSION}" == "HEAD" ]]; then
	if [[ -n "${LOCAL}" ]]; then
		BINUTILS_BRANCH="${BINUTILS_VERSION}"
	else
		BINUTILS_BRANCH="master"
	fi
else
	# Look on binutils git repo
	gitlist=($(git ls-remote --heads "${BINUTILS_GIT_URL}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))
	for i in "${!gitlist[@]}"; do
		if [[ "${gitlist[i]}" == "binutils-${BINUTILS_VERSION//\./_}-branch" ]]; then
			BINUTILS_BRANCH="binutils-${BINUTILS_VERSION//\./_}-branch"
			break
		fi
	done
fi

[[ ! "${BINUTILS_BRANCH}" ]] && { echo "Can't find a branch with binutils ${BINUTILS_VERSION}" ; exit 1 ; }

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

if [[ -n "${LOCAL}" ]]; then
	echo "Linking existing sources..."
	ln -s "${GCC_GIT_URL}" gcc || { echo "Failed to link to existing gcc repo at ${GCC_GIT_URL}" ; exit 1 ; }
	ln -s "${BINUTILS_GIT_URL}" binutils-gdb || { echo "Failed to link to existing binutils repo at ${BINUTILS_GIT_URL}" ; exit 1 ; }
else
	echo "Cloning sources..."
	# We have a branch, so let's continue
	git clone ${GCC_REFERENCE} -b "${GCC_BRANCH}" --depth=1 -q "${GCC_GIT_URL}" 2>/dev/null || { echo "Failed to clone gcc git repo, exiting." ; exit 1 ; } && ( cd gcc; echo -e "\nLatest GCC commit:\n" ; git --no-pager log -1)
	# Get binutils
	git clone ${BINUTILS_REFERENCE} -b "${BINUTILS_BRANCH}" --depth=1 -q "${BINUTILS_GIT_URL}" || { echo "Failed to clone binutils git repo, exiting." ; exit 1 ; } && ( cd binutils-gdb; echo -e "\nLatest binutils commit:\n" ; git --no-pager log -1 )
fi

cd "${SRC_DIR}/gcc" && GCC_SHA1="$(git rev-parse HEAD)"
cd "${SRC_DIR}/binutils-gdb" && BINUTILS_SHA1="$(git rev-parse HEAD)"

#Get version of GCC, according to the repo
GCC_VERSION="$(< "${SRC_DIR}/gcc/gcc/BASE-VER")"

if [[ "${GLIBC_VERSION}" != "" ]]; then
	echo "Getting dependencies for glibc..."
	# Get deps for libc
	cd "${SRC_DIR}"

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
if [[ "${GLIBC_VERSION}" != "" ]];
then
	# Install Linux headers
	echo -e "\nInstalling Linux headers ..."
	cd "${SRC_DIR}/linux"
	make ARCH="${ARCH_LINUX}" INSTALL_HDR_PATH="${SYSROOT}/usr" headers_install
else
	mkdir -p "${SYSROOT}"
fi

# Build binutils
echo -e "\nBuilding binutils ..."
mkdir -p "${BUILD_DIR}/binutils" && cd "${BUILD_DIR}/binutils"
../../src/binutils-gdb/configure --prefix="${PREFIX}" ${TARGETS} --with-sysroot="${SYSROOT}"

make -s ${JOBS} && make -s install

# Build GCC
echo -e "\nBuilding gcc ..."
mkdir -p "${BUILD_DIR}/gcc" && cd "${BUILD_DIR}/gcc"
../../src/gcc/configure --prefix="${PREFIX}" ${TARGETS} --enable-languages=c,c++ --disable-bootstrap --disable-multilib --with-long-double-128 --with-sysroot="${SYSROOT}"
make -s gcc_cv_libc_provides_ssp=yes all-gcc ${JOBS} && make -s install-gcc

# Write gcc and binutils version and git hash to file
cat > "${BASEDIR}/version" << EOF
GCC_VERSION=${GCC_VERSION}
GCC_SHA1=${GCC_SHA1}
BINUTILS_VERSION=${BINUTILS_VERSION}
BINUTILS_SHA1=${BINUTILS_SHA1}
EOF

if [[ "${GLIBC_VERSION}" != "" ]];
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
