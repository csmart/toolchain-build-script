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
	echo " * From ${branch} on ${GIT_URL_GCC}"
	echo " * Using binutils ${BINUTILS_VERSION}"
	if [[ "${INSTALL}" != "false" ]]; then
		echo -e " * Install to:\n\t${INSTALL}/gcc-${VERSION}-nolibc/${NAME}/"
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
[[ "$(git ls-remote --tags --heads "${GIT_URL_GCC}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact gcc git server" ; exit 1 )
[[ "$(git ls-remote --tags --heads "${GIT_URL_BINUTILS}" 2>/dev/null)" ]] || ( echo "ERROR: Couldn't contact binutils git server" ; exit 1 )

# Get a list of all tags and branches from the specified git server
gitlist=($(git ls-remote --tags --heads "${GIT_URL_GCC}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))

# Error if we couldn't get tags or branches from git server
if [[ "${#gitlist[*]}" -eq 0 ]]; then
	# We didn't find anything
	echo "ERROR: Couldn't get anything from the git server at ${GIT_URL_GCC}"
	exit 1
fi

# Check if we have the version specified in either a tag or branch
# Tags follow format gcc-<version>-release, e.g. gcc-5_1_0-release

branch=""
for i in "${!gitlist[@]}"; do
	# check for tags first
	if [[ "${gitlist[i]}" == "gcc-${VERSION//\./_}-release" ]]; then
		branch="gcc-${VERSION//\./_}-release"
		break
		# check for branches next
	elif [[ "${gitlist[i]}" == "${VERSION}" ]]; then
		branch="${VERSION}"
		break
		# if local then HEAD, else master
	elif [[ "${VERSION}" == "HEAD" ]]; then
		if [[ -n "${LOCAL}" ]]; then
			branch="${VERSION}"
			break
		else
			branch="master"
			break
		fi
	fi
done

# Else we can't find what we're looking for
if [[ -z "${branch}" ]]; then
	echo "Could not find the version, ${VERSION}"
	if [[ "${GIT_URL_GCC:0:1}" == "/" || "${GIT_URL_GCC:0:1}" == "~" ]]; then
		echo "If this is a local repo, you might not have that branch."
		echo "Try checking out the branch or use a tag."
	fi
	exit 1
fi

# Get a list of all tags and branches from the specified git server
gitlist=($(git ls-remote --heads "${GIT_URL_BINUTILS}" 2>/dev/null |awk -F "/" '{print $NF}' |sort |uniq))

# Look for binutils branch
branch_binutils=""
if [[ "${BINUTILS_VERSION}" == "master" ]]; then
	branch_binutils="master"
else
	for i in "${!gitlist[@]}"; do
		if [[ "${gitlist[i]}" == "binutils-${BINUTILS_VERSION//\./_}-branch" ]]; then
			branch_binutils="binutils-${BINUTILS_VERSION//\./_}-branch"
			break
		fi
	done
fi
[[ ! "${branch_binutils}" ]] && { echo "Can't find a branch with binutils ${BINUTILS_VERSION}" ; exit 1 ; }

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
cd src

if [[ -n "${LOCAL}" ]]; then
	echo "Linking existing sources..."
	ln -s "${GIT_URL_GCC}" gcc || { echo "Failed to link to existing gcc repo at ${GIT_URL_GCC}" ; exit 1 ; }
	ln -s "${GIT_URL_BINUTILS}" binutils-gdb || { echo "Failed to link to existing binutils repo at ${GIT_URL_BINUTILS}" ; exit 1 ; }
else
	echo "Cloning sources..."
	# We have a branch, so let's continue
	git clone ${GCC_REFERENCE} -b "${branch}" --depth=1 -q "${GIT_URL_GCC}" 2>/dev/null || { echo "Failed to clone gcc git repo, exiting." ; exit 1 ; } && ( cd gcc; echo -e "\nLatest GCC commit:\n" ; git --no-pager log -1 )
	# Get binutils
	git clone ${BINUTILS_REFERENCE} -b "${branch_binutils}" --depth=1 -q "${GIT_URL_BINUTILS}" || { echo "Failed to clone binutils git repo, exiting." ; exit 1 ; } && ( cd binutils-gdb; echo -e "\nLatest binutils commit:\n" ; git --no-pager log -1 )
fi

#Get version of GCC, according to the repo
VERSION="$(< gcc/gcc/BASE-VER)"

# Build binutils
echo -e "\nBuilding binutils ..."
cd "${BASEDIR}/build/binutils"
../../src/binutils-gdb/configure --disable-gdb --disable-libdecnumber --disable-readline --disable-sim --prefix="${BASEDIR}/install/${NAME}" ${TARGETS}

make -s ${JOBS}
make -s install

# Build gcc
echo -e "\nBuilding gcc ..."
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
