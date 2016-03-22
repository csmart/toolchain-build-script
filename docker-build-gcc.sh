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
PROXY=""

# Timestamp for job
echo "Build started, $(date)"

# Make sure we have a build.sh file
if [[ ! -f "${WORKSPACE}/build.sh" ]]; then
	echo "No build.sh file in ${WORKSPACE}"
	exit 1
fi

# Configure docker build

if [[ -n "${http_proxy}" ]]; then
	PROXY="RUN echo "proxy=${http_proxy}" >> /etc/dnf/dnf.conf"
fi

Dockerfile=$(cat << EOF
FROM fedora:23

${PROXY}

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
	socat \
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

# Run the docker container, execute the build script we just built
docker run \
	--net=host \
	--rm=true \
	-e WORKSPACE=${WORKSPACE} \
	--user="${USER}" \
	-w "${HOME}" \
	-v "${HOME}":"${HOME}":Z \
	-t gcc-build/fedora \
	${WORKSPACE}/build.sh

# Timestamp for build
echo "Build completed, $(date)"
