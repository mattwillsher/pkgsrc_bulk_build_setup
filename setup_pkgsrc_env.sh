#!/bin/bash
#
# Scriptification of http://www.perkin.org.uk/posts/distributed-chrooted-pkgsrc-bulk-builds.html
#
# (c) Jonathan Perkin, 2013
# (c) Matt Willsher <matt@monki.org.uk>, 2013
#
# Work in progress!
#

PKGSRC_REPO='https://github.com/jsonn/pkgsrc'
PKGSRC_BRANCH='2013Q2'
CONTENT_ROOT='/content'
PROVIDER_DIR='monki/' # This can be a LANANA name or similar

OPT_PATH="/opt/${PROVIDER_DIR}local" # Path for /, /etc and /var anchoring
PBULK_PATH="/opt/${PROVIDER_DIR}pbulk"

set -e
set -x

if [[ $EUID != 0 ]]; then
  echo "Script needs to be run as root"
  exit 1
fi

mkdir -p ${CONTENT_ROOT}/{distfiles,mk,packages/bootstrap,scripts}

cat >${CONTENT_ROOT}/mk/mk-generic.conf <<EOF
ALLOW_VULNERABLE_PACKAGES=	yes
SKIP_LICENSE_CHECK=		yes
DISTDIR=			${CONTENT_ROOT}/distfiles

# If your system has a native curl, this avoids building nbftp
FAILOVER_FETCH=		yes
FETCH_USING=		curl

# Change this to a closer mirror (http://www.netbsd.org/mirrors)
MASTER_SITE_OVERRIDE=	ftp://ftp.nl.NetBSD.org/pub/NetBSD/packages/distfiles/

# Tweak this for your system, though take into account how many concurrent
# chroots you may want to run too.
MAKE_JOBS=		4
EOF

cat >${CONTENT_ROOT}/mk/mk-pbulk.conf <<EOF
.include "${CONTENT_ROOT}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_ROOT}/packages/${PKGSRC_BRANCH}/pbulk
WRKOBJDIR=	/var/tmp/pkgbuild
EOF

cat >${CONTENT_ROOT}/mk/mk-pkg.conf <<EOF
.include "${CONTENT_ROOT}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_ROOT}/packages/${PKGSRC_BRANCH}/x86_64
WRKOBJDIR=	/home/pbulk/build
EOF

pushd $CONTENT_ROOT
[[ -d pkgsrc ]] || git clone ${PKGSRC_REPO}

pushd pkgsrc
git checkout pkgsrc_${PKGSRC_BRANCH}

# Apply patches but verify their checksums first
declare -A patches
patches["mksandbox-1.3.diff"]="a010aeb1ac05474b889e370113f8f0e1" 
patches["pbulk-joyent.diff"]="b87c6d78b116708aae94b1a92bf13e86" 
for patch_file in "${!patches[@]}"
do
  echo -n Applying patch ${patch_file}:  ' '
  curl -Os http://www.netbsd.org/~jperkin/${patch_file}
  md5sum $patch_file | grep ^${patches["$patch_file"]}' ' >/dev/null ||
    ( echo error checksum mismatch ; exit 1 )
  patch -p0 -N -s -r- -i $patch_file 2>&1 >/dev/null || true
  rm $patch_file
  echo OK
done

if [[ ! -d /opt/${PROVIDER_DIR}pbulk ]]
then
  pushd bootstrap
  ./bootstrap --abi=64 --prefix=${PBULK_PATH} \
    --mk-fragment=${CONTENT_ROOT}/mk/mk-pbulk.conf \
    --prefer-pkgsrc yes
  ./cleanup
  popd
fi

PATH=${PBULK_PATH}/sbin:${PBULK_PATH}/bin:$PATH
for pkg in pkgtools/pbulk pkgtools/mksandbox
do
  pushd $pkg
  bmake package-install
  popd
done
