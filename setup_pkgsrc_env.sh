#!/bin/bash
#
# Scriptification of http://www.perkin.org.uk/posts/distributed-chrooted-pkgsrc-bulk-builds.html
#
# (c) Jonathan Perkin, 2013
# (c) Matt Willsher <matt@monki.org.uk>, 2013
#
# Work in progress!
#

# Edit these
PKGSRC_BRANCH='2013Q2' # pkgsrc branch to use
PROVIDER_NAME='monki' # This can be a LANANA name or similar. Used for folder under /opt

# These are default paths
CONTENT_PATH='/content' # Root of content tree
PROVIDER_DIR="${PROVIDER_NAME}/"
OPT_PATH="/opt/${PROVIDER_DIR}local" # Path for /, /etc and /var anchoring
PBULK_PATH="/opt/${PROVIDER_DIR}pbulk" # Location for pbulk install
CHROOT_PATH="/chroot"

PKGSRC_REPO='https://github.com/jsonn/pkgsrc' # Where to get pkgsrc tree from
PREFER_PKGSRC='yes' # Value to set prefer-pkgsrc to during bootstrap

set -e

if [[ $EUID != 0 ]]; then
  echo "Script needs to be run as root"
  exit 1
fi

export SH=/bin/bash

echo "Creating initial content tree under $CONTENT_PATH"

mkdir -p ${CONTENT_PATH}/{distfiles,mk,packages/bootstrap,scripts}

[[ -f ${CONTENT_PATH}/mk/mk-generic.conf ]] ||
  cat >${CONTENT_PATH}/mk/mk-generic.conf <<EOF
ALLOW_VULNERABLE_PACKAGES=	yes
SKIP_LICENSE_CHECK=		yes
DISTDIR=			${CONTENT_PATH}/distfiles

# If your system has a native curl, this avoids building nbftp
FAILOVER_FETCH=		yes
FETCH_USING=		curl

# Change this to a closer mirror (http://www.netbsd.org/mirrors)
MASTER_SITE_OVERRIDE=	ftp://ftp.nl.NetBSD.org/pub/NetBSD/packages/distfiles/

# Tweak this for your system, though take into account how many concurrent
# chroots you may want to run too.
MAKE_JOBS=		4
EOF

cat >${CONTENT_PATH}/mk/mk-pbulk.conf <<EOF
.include "${CONTENT_PATH}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_PATH}/packages/${PKGSRC_BRANCH}/pbulk
WRKOBJDIR=	/var/tmp/pkgbuild
EOF

cat >${CONTENT_PATH}/mk/mk-pkg.conf <<EOF
.include "${CONTENT_PATH}/mk/mk-generic.conf"

PACKAGES=	${CONTENT_PATH}/packages/${PKGSRC_BRANCH}/x86_64
WRKOBJDIR=	/home/pbulk/build
PREFER_PKGSRC=  yes
EOF

echo Checking out ${CONTENT_PATH}/pkgsrc

pushd $CONTENT_PATH
[[ -d pkgsrc ]] ||
  git clone ${PKGSRC_REPO}

pushd pkgsrc
git checkout pkgsrc_${PKGSRC_BRANCH}

# Apply patches but verify their checksums first
declare -A patches
patches["mksandbox-1.3.diff"]="a010aeb1ac05474b889e370113f8f0e1"
patches["pbulk-joyent.diff"]="b87c6d78b116708aae94b1a92bf13e86"
for patch_file in "${!patches[@]}"
do
  [[ -f .${patch_file}.done ]] && continue  # Skip if already applied
  echo Applying patch $patch_file
  curl -Os http://www.netbsd.org/~jperkin/${patch_file}
  md5sum $patch_file | grep ^${patches["$patch_file"]}' ' >/dev/null ||
    ( echo error checksum mismatch ; exit 1 )
  patch -p0 -N -t -s -r- -i $patch_file 
  mv $patch_file .${patch_file}.done
done


if [[ ! -f ${PBULK_PATH}/bin/bmake ]]
then
  echo "Building pbulk bootstrap"
  pushd bootstrap
  [[ -d work ]] && rm -r work
  ./bootstrap --abi=64 --prefix=${PBULK_PATH} \
    --mk-fragment=${CONTENT_PATH}/mk/mk-pbulk.conf \
    --prefer-pkgsrc ${PREFER_PKGSRC}
  ./cleanup
  popd
fi

PATH=${PBULK_PATH}/sbin:${PBULK_PATH}/bin:$PATH
for pkg in pkgtools/pbulk pkgtools/mksandbox
do
  echo Building $pkg
  pushd $pkg
  CFLAGS=-Wno-unused-result bmake package-install
  popd
done

id pbulk >/dev/null ||
  ( groupadd pbulk && useradd -g pbulk -c 'pkgsrc pbulk user' -m -s /bin/bash pbulk )

## Update shell path if profile.d is used
if [[ -d /etc/profile.d ]]
then
  cat >/etc/profile.d/pkgsrc-pbulk.sh <<EOF
PATH=${PBULK_PATH}/sbin:${PBULK_PATH}/bin:\$PATH
export PATH
EOF
else
  cat >>EOF
Remember to update your shell PATH env var to include
${PBULK_PATH}/sbin and ${PBULK_PATH}/bin
EOF
fi

# Setup chroot
[[ -d ${CHROOT_PATH} ]] ||
  mkdir ${CHROOT_PATH}

cat >${CONTENT_PATH}/scripts/mksandbox <<EOF
#!/bin/sh

chrootdir=\$1; shift

while true
do
	# XXX: limited_list builds can recreate chroots too fast.
	if [ -d \${chrootdir} ]; then
		echo "Chroot \${chrootdir} exists, retrying in 10 seconds or ^C to quit"
		sleep 10
	else
		break
	fi
done

${PBULK_PATH}/sbin/mksandbox --without-pkgsrc \\
  --rodirs=${PBULK_PATH} --rwdirs=${CONTENT_PATH} \${chrootdir} >/dev/null 2>&1
mkdir -p \${chrootdir}/home/pbulk
chown pbulk:pbulk \${chrootdir}/home/pbulk
EOF

cat >${CONTENT_PATH}/scripts/rmsandbox <<EOF
#!/bin/sh

chrootdir=\`echo \$1 | sed -e 's,/\$,,'\`; shift

if [ -d \${chrootdir} ]; then
	#
	# Try a few times to unmount the sandbox, just in case there are any
	# lingering processes holding mounts open.
	#
	for retry in 1 2 3
	do
		\${chrootdir}/sandbox umount >/dev/null 2>&1
		mounts=\`mount -v | grep "\${chrootdir}/"\`
		if [ -z "\${mounts}" ]; then
			rm -rf \${chrootdir}
			break
		else
			sleep 5
		fi
	done
fi
EOF

chmod +x ${CONTENT_PATH}/scripts/{rm,mk}sandbox

# Create bootstrap
if [[ ! -f ${CONTENT_PATH}/packages/bootstrap/bootstrap-${PKGSRC_BRANCH}-pbulk.tar.gz ]]
then
  [[ -d ${CHROOT_PATH}/build-bootstrap ]] ||
    ${CONTENT_PATH}/scripts/mksandbox ${CHROOT_PATH}/build-bootstrap

  cat >${CHROOT_PATH}/build-bootstrap/build-bootstrap.sh <<EOF
#!/bin/bash

export SH=/bin/bash

cd ${CONTENT_PATH}/pkgsrc/bootstrap
./bootstrap --abi 64 \
  --gzip-binary-kit ${CONTENT_PATH}/packages/bootstrap/bootstrap-${PKGSRC_BRANCH}-pbulk.tar.gz \
  --mk-fragment ${CONTENT_PATH}/mk/mk-pkg.conf \
  --prefer-pkgsrc ${PREFER_PKGSRC} \
  --prefix ${OPT_PATH} \
  --varbase /var${OPT_PATH} \
  --sysconfdir /etc${OPT_PATH} \
  --pkgdbdir=/var${OPT_PATH}/db/pkg
./cleanup
EOF

  echo "Building real environment bootstrap"
  chmod +x ${CHROOT_PATH}/build-bootstrap/build-bootstrap.sh
  ${CHROOT_PATH}/build-bootstrap/sandbox /build-bootstrap.sh
  ${CONTENT_PATH}/scripts/rmsandbox ${CHROOT_PATH}/build-bootstrap
fi

echo "Now edit ${PBULK_PATH}/etc/pbulk.conf and you're good to go"

echo "DONE"

exit 0


