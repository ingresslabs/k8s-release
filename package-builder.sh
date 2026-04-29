#!/bin/bash
set -euo pipefail

# This script creates Debian and RPM packages from a binary
# Usage: ./package-builder.sh <binary_name> <version> <description>

BINARY_NAME=${1:?binary name is required}
VERSION=${2:?version is required}
DESCRIPTION=${3:?description is required}
PACKAGE_TYPE=${PACKAGE_TYPE:-deb}  # Default to deb if not specified
PKG_MAINTAINER=${PKG_MAINTAINER:-Kubernetes Packager <maintainer@example.com>}
PKG_LICENSE=${PKG_LICENSE:-Apache-2.0}
PKG_URL=${PKG_URL:-https://kubernetes.io}
PKG_ARCH=${PKG_ARCH:-amd64}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

case "${PKG_ARCH}" in
    amd64|x86_64)
        DEB_ARCH=amd64
        RPM_ARCH=x86_64
        ;;
    arm64|aarch64)
        DEB_ARCH=arm64
        RPM_ARCH=aarch64
        ;;
    *)
        echo "ERROR: unsupported PKG_ARCH '${PKG_ARCH}'. Supported values: amd64, x86_64, arm64, aarch64."
        exit 1
        ;;
esac

if ! [[ "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SOURCE_DATE_EPOCH must be a Unix timestamp, got '${SOURCE_DATE_EPOCH}'."
    exit 1
fi

BUILD_DATE=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%a %b %d %Y' 2>/dev/null || date -u '+%a %b %d %Y')

# Strip 'v' prefix from version if present (Debian requires versions to start with a digit)
VERSION=${VERSION#v}

# Create directory structure for the Debian package
PKG_DIR="/tmp/${BINARY_NAME}_${VERSION}"
mkdir -p ${PKG_DIR}/usr/local/bin
mkdir -p ${PKG_DIR}/DEBIAN
mkdir -p ${PKG_DIR}/lib/systemd/system
mkdir -p ${PKG_DIR}/etc/kubernetes
mkdir -p ${PKG_DIR}/etc/etcd

# Copy binary to the package directory
cp /usr/local/bin/$BINARY_NAME ${PKG_DIR}/usr/local/bin/

# Create control file
cat > ${PKG_DIR}/DEBIAN/control << EOF
Package: $BINARY_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Maintainer: $PKG_MAINTAINER
Description: $DESCRIPTION
EOF

# Create postinst script to enable systemd service (only for services, not for CLI tools like etcdctl)
if [ "${BINARY_NAME}" != "etcdctl" ]; then
    cat > ${PKG_DIR}/DEBIAN/postinst << EOF
#!/bin/bash
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ${BINARY_NAME}.service >/dev/null 2>&1 || true
    echo "The ${BINARY_NAME} service has been enabled. To start it, run: sudo systemctl start ${BINARY_NAME}"
fi
EOF
    chmod 755 ${PKG_DIR}/DEBIAN/postinst

    # Create prerm script to disable systemd service before removal
    cat > ${PKG_DIR}/DEBIAN/prerm << EOF
#!/bin/bash
if [ -d /run/systemd/system ]; then
    systemctl disable ${BINARY_NAME}.service >/dev/null 2>&1 || true
    systemctl stop ${BINARY_NAME}.service >/dev/null 2>&1 || true
fi
EOF
    chmod 755 ${PKG_DIR}/DEBIAN/prerm
else
    # For CLI tools, create a simpler postinst script
    cat > ${PKG_DIR}/DEBIAN/postinst << EOF
#!/bin/bash
echo "${BINARY_NAME} has been installed. You can run it from the command line."
EOF
    chmod 755 ${PKG_DIR}/DEBIAN/postinst
fi

# Copy systemd service file if it exists and if this is not etcdctl
if [ -f /systemd-units/${BINARY_NAME}.service ] && [ "${BINARY_NAME}" != "etcdctl" ]; then
    cp /systemd-units/${BINARY_NAME}.service ${PKG_DIR}/lib/systemd/system/
    echo "Copied systemd service file for ${BINARY_NAME}"
fi

# Copy configuration files based on binary name
case "$BINARY_NAME" in
    etcd)
        if [ -f /config-files/etcd.conf.yaml ]; then
            mkdir -p ${PKG_DIR}/etc/etcd
            cp /config-files/etcd.conf.yaml ${PKG_DIR}/etc/etcd/
            echo "Copied etcd config file"
        fi
        ;;
    kubelet)
        if [ -f /config-files/kubelet-config.yaml ]; then
            cp /config-files/kubelet-config.yaml ${PKG_DIR}/etc/kubernetes/
            echo "Copied kubelet config file"
        fi
        ;;
    kube-proxy)
        if [ -f /config-files/kube-proxy-config.yaml ]; then
            cp /config-files/kube-proxy-config.yaml ${PKG_DIR}/etc/kubernetes/
            echo "Copied kube-proxy config file"
        fi
        ;;
    *)
        # No specific config files for other binaries
        ;;
esac

# Always create the output directory
mkdir -p /output

# Preserve local config files during package upgrades.
CONFFILES=$(find "${PKG_DIR}/etc" -type f 2>/dev/null | sed "s#^${PKG_DIR}##" || true)
if [ -n "${CONFFILES}" ]; then
    printf '%s\n' "${CONFFILES}" > "${PKG_DIR}/DEBIAN/conffiles"
fi

# Normalize mtimes so dpkg/rpm archives are stable for the same source input.
if touch -d "@${SOURCE_DATE_EPOCH}" "${PKG_DIR}" >/dev/null 2>&1; then
    find "${PKG_DIR}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
fi

# Build packages based on PACKAGE_TYPE
if [ "$PACKAGE_TYPE" = "deb" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    # Create the Debian package
    echo "Building Debian package for ${BINARY_NAME}..."
    DEB_FILE="/output/${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
    dpkg-deb --root-owner-group --build ${PKG_DIR} "${DEB_FILE}"
    echo "Debian package build completed"

    # Verify the Debian package exists
    if [ -f "${DEB_FILE}" ]; then
        echo "Debian package successfully created at ${DEB_FILE}"
        # Copy the Debian package to the root directory for easier access
        cp "${DEB_FILE}" "/${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
        chmod 644 "/${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
    else
        echo "ERROR: Debian package creation failed!"
        [ "$PACKAGE_TYPE" = "all" ] || exit 1
    fi
fi

if [ "$PACKAGE_TYPE" = "rpm" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    # Build the RPM package
    echo "Building RPM package for ${BINARY_NAME}..."
    
    # Initialize RPM_FILE variable
    RPM_FILE=""

# Create RPM build directory structure
RPM_BUILD_DIR="/tmp/rpmbuild"
mkdir -p ${RPM_BUILD_DIR}/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create a tarball of the binary
TARBALL_DIR="/tmp/${BINARY_NAME}-${VERSION}"
mkdir -p ${TARBALL_DIR}/usr/local/bin
mkdir -p ${TARBALL_DIR}/lib/systemd/system
mkdir -p ${TARBALL_DIR}/etc/kubernetes
mkdir -p ${TARBALL_DIR}/etc/etcd

# Copy binary to the tarball directory
cp /usr/local/bin/$BINARY_NAME ${TARBALL_DIR}/usr/local/bin/

# Copy systemd service file if it exists and if this is not etcdctl
if [ -f /systemd-units/${BINARY_NAME}.service ] && [ "${BINARY_NAME}" != "etcdctl" ]; then
    cp /systemd-units/${BINARY_NAME}.service ${TARBALL_DIR}/lib/systemd/system/
fi

# Copy configuration files based on binary name
case "$BINARY_NAME" in
    etcd)
        if [ -f /config-files/etcd.conf.yaml ]; then
            mkdir -p ${TARBALL_DIR}/etc/etcd
            cp /config-files/etcd.conf.yaml ${TARBALL_DIR}/etc/etcd/
        fi
        ;;
    kubelet)
        if [ -f /config-files/kubelet-config.yaml ]; then
            cp /config-files/kubelet-config.yaml ${TARBALL_DIR}/etc/kubernetes/
        fi
        ;;
    kube-proxy)
        if [ -f /config-files/kube-proxy-config.yaml ]; then
            cp /config-files/kube-proxy-config.yaml ${TARBALL_DIR}/etc/kubernetes/
        fi
        ;;
    *)
        # No specific config files for other binaries
        ;;
esac

# Create the tarball
cd /tmp
if touch -d "@${SOURCE_DATE_EPOCH}" "${TARBALL_DIR}" >/dev/null 2>&1; then
    find "${TARBALL_DIR}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
fi
tar --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -czf ${RPM_BUILD_DIR}/SOURCES/${BINARY_NAME}-${VERSION}.tar.gz ${BINARY_NAME}-${VERSION}

# Create the spec file
cat > ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
Name:           ${BINARY_NAME}
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        ${DESCRIPTION}

License:        ${PKG_LICENSE}
URL:            ${PKG_URL}
Source0:        ${BINARY_NAME}-${VERSION}.tar.gz

BuildArch:      ${RPM_ARCH}
Requires:       systemd

%description
${DESCRIPTION}

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/local/bin
install -m 755 usr/local/bin/${BINARY_NAME} %{buildroot}/usr/local/bin/

EOF

# Add systemd service file to spec if it exists
if [ -f /systemd-units/${BINARY_NAME}.service ] && [ "${BINARY_NAME}" != "etcdctl" ]; then
    cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
mkdir -p %{buildroot}/lib/systemd/system
install -m 644 lib/systemd/system/${BINARY_NAME}.service %{buildroot}/lib/systemd/system/
EOF
fi

# Add config files to spec based on binary name
case "$BINARY_NAME" in
    etcd)
        if [ -f /config-files/etcd.conf.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
mkdir -p %{buildroot}/etc/etcd
install -m 644 etc/etcd/etcd.conf.yaml %{buildroot}/etc/etcd/
EOF
        fi
        ;;
    kubelet)
        if [ -f /config-files/kubelet-config.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
mkdir -p %{buildroot}/etc/kubernetes
install -m 644 etc/kubernetes/kubelet-config.yaml %{buildroot}/etc/kubernetes/
EOF
        fi
        ;;
    kube-proxy)
        if [ -f /config-files/kube-proxy-config.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
mkdir -p %{buildroot}/etc/kubernetes
install -m 644 etc/kubernetes/kube-proxy-config.yaml %{buildroot}/etc/kubernetes/
EOF
        fi
        ;;
    *)
        # No specific config files for other binaries
        ;;
esac

# Complete the spec file with files section and scripts
cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%files
%attr(755, root, root) /usr/local/bin/${BINARY_NAME}
EOF

# Add systemd service file to files section if it exists
if [ -f /systemd-units/${BINARY_NAME}.service ] && [ "${BINARY_NAME}" != "etcdctl" ]; then
    cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%attr(644, root, root) /lib/systemd/system/${BINARY_NAME}.service
EOF
fi

# Add config files to files section based on binary name
case "$BINARY_NAME" in
    etcd)
        if [ -f /config-files/etcd.conf.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%attr(644, root, root) /etc/etcd/etcd.conf.yaml
EOF
        fi
        ;;
    kubelet)
        if [ -f /config-files/kubelet-config.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%attr(644, root, root) /etc/kubernetes/kubelet-config.yaml
EOF
        fi
        ;;
    kube-proxy)
        if [ -f /config-files/kube-proxy-config.yaml ]; then
            cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%attr(644, root, root) /etc/kubernetes/kube-proxy-config.yaml
EOF
        fi
        ;;
    *)
        # No specific config files for other binaries
        ;;
esac

# Add post and preun scripts for systemd services
if [ "${BINARY_NAME}" != "etcdctl" ]; then
    cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%post
if [ \$1 -eq 1 ] ; then
    # Initial installation
    systemctl daemon-reload >/dev/null 2>&1 || :
    systemctl enable ${BINARY_NAME}.service >/dev/null 2>&1 || :
    echo "The ${BINARY_NAME} service has been enabled. To start it, run: sudo systemctl start ${BINARY_NAME}"
fi

%preun
if [ \$1 -eq 0 ] ; then
    # Package removal, not upgrade
    systemctl --no-reload disable ${BINARY_NAME}.service >/dev/null 2>&1 || :
    systemctl stop ${BINARY_NAME}.service >/dev/null 2>&1 || :
fi
EOF
fi

# Finish the spec file
cat >> ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec << EOF
%changelog
* ${BUILD_DATE} ${PKG_MAINTAINER} - ${VERSION}-1
- Initial package
EOF

# Build the RPM package
rpmbuild \
    --define "_topdir ${RPM_BUILD_DIR}" \
    --define "source_date_epoch ${SOURCE_DATE_EPOCH}" \
    --define "clamp_mtime_to_source_date_epoch 1" \
    -bb ${RPM_BUILD_DIR}/SPECS/${BINARY_NAME}.spec

# Copy the RPM to the output directory
find ${RPM_BUILD_DIR}/RPMS -name "*.rpm" -exec cp {} /output/ \;

# Verify the RPM package exists
RPM_FILE=$(find /output -name "${BINARY_NAME}-${VERSION}*.rpm")
if [ -n "${RPM_FILE}" ]; then
    echo "RPM package successfully created at ${RPM_FILE}"
    # Copy the RPM package to the root directory for easier access
    cp ${RPM_FILE} /$(basename ${RPM_FILE})
    chmod 644 /$(basename ${RPM_FILE})
else
    echo "ERROR: RPM package creation failed!"
    [ "$PACKAGE_TYPE" = "all" ] || exit 1
fi

# Ensure the output directory is accessible
chmod -R 777 /output

echo "Packages created:"
ls -la /output

# List package contents for Debian packages
if [ "$PACKAGE_TYPE" = "deb" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    DEB_FILE="/output/${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
    if [ -f "$DEB_FILE" ]; then
        echo "Contents of $DEB_FILE:"
        dpkg -c "$DEB_FILE"
        
        echo "Package information for $DEB_FILE:"
        dpkg -I "$DEB_FILE"
    fi
fi

# List package contents for RPM packages
if [ "$PACKAGE_TYPE" = "rpm" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    if [ -n "${RPM_FILE}" ]; then
        echo "Contents of ${RPM_FILE}:"
        rpm -qlp "${RPM_FILE}" 2>/dev/null || echo "Could not list RPM contents (rpm command may not be available)"
        
        echo "Package information for ${RPM_FILE}:"
        rpm -qip "${RPM_FILE}" 2>/dev/null || echo "Could not show RPM info (rpm command may not be available)"
    fi
fi

# Copy message based on what was built
if [ "$PACKAGE_TYPE" = "deb" ]; then
    echo "Copied package to: /${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
elif [ "$PACKAGE_TYPE" = "rpm" ] && [ -n "${RPM_FILE}" ]; then
    echo "Copied package to: /$(basename ${RPM_FILE})"
elif [ "$PACKAGE_TYPE" = "all" ]; then
    DEB_FILE="/${BINARY_NAME}_${VERSION}_${DEB_ARCH}.deb"
    RPM_BASE=""
    if [ -n "${RPM_FILE}" ]; then
        RPM_BASE=$(basename ${RPM_FILE})
    fi
    
    if [ -f "$DEB_FILE" ] && [ -n "$RPM_BASE" ] && [ -f "/$RPM_BASE" ]; then
        echo "Copied packages to: $DEB_FILE and /$RPM_BASE"
    elif [ -f "$DEB_FILE" ]; then
        echo "Copied package to: $DEB_FILE"
    elif [ -n "$RPM_BASE" ] && [ -f "/$RPM_BASE" ]; then
        echo "Copied package to: /$RPM_BASE"
    else
        echo "No packages were successfully copied"
    fi
fi
fi
