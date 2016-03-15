#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   WORKSPACE =

# Trace bash processing
set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}

# Timestamp for job
echo "Build started, $(date)"

# Configure docker build

Dockerfile=$(cat << EOF
FROM fedora:23

RUN dnf --refresh repolist && dnf install -y \
	bison \
	ccache \
	file \
	flex \
	gcc \
	gcc-c++ \
	git \
	gmp-devel \
	libmpc-devel \
	make \
	mpfr-devel \
	tar \
	texinfo \
	xz

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

# Build the docker container
docker build -t gcc-build/fedora - <<< "${Dockerfile}"
if [[ "$?" -ne 0 ]]; then
  echo "Failed to build docker container."
  exit 1
fi

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

export CC="ccache gcc"
mkdir -p "${WORKSPACE}/gcc-build"
mkdir -p "${WORKSPACE}/cross"

cd "${WORKSPACE}/toolchain-build-script"
./build-gcc.sh \
	-v HEAD \
	-t ppc \
	-b ${WORKSPACE}/gcc-build \
	-i ${WORKSPACE}/cross --gcc ${WORKSPACE}/gcc \
	--binutils ${WORKSPACE}/binutils-gdb \
	--local \
	--clean

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}":Z -t gcc-build/fedora ${WORKSPACE}/build.sh

# Timestamp for build
echo "Build completed, $(date)"
