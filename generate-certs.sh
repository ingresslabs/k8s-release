#!/bin/bash
set -euo pipefail

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

# Create output directories
mkdir -p /certs /output

# Create CA
echo "Generating CA certificates..."
openssl genrsa -out /certs/ca.key 4096
openssl req -x509 -new -sha512 -nodes \
  -key /certs/ca.key -days 3653 \
  -config /ca.conf \
  -out /certs/ca.crt

# Create certificates for each component
certs=(
  "admin" "node-0" "node-1"
  "kube-proxy" "kube-scheduler"
  "kube-controller-manager"
  "kube-api-server"
  "service-accounts"
)

for i in ${certs[*]}; do
  echo "Generating certificates for ${i}..."
  openssl genrsa -out "/certs/${i}.key" 4096

  # Create a temporary config file for this specific component with a more complete structure
  cat > "/tmp/${i}.conf" << EOF
[ req ]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[ dn ]
C = US
ST = California
L = San Francisco
O = Kubernetes
OU = K8s release
CN = ${i}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
EOF

  # Add the appropriate extensions section from ca.conf
  if grep -q "\[ ${i} \]" /ca.conf; then
    # Extract the section and any referenced sections
    sed -n "/\[ ${i} \]/,/\[/p" /ca.conf | sed '$d' >> "/tmp/${i}.conf"
    
    # If this component references another section (like alt_names), extract that too
    if grep -q "subjectAltName = @alt_names_${i}" "/tmp/${i}.conf"; then
      sed -n "/\[ alt_names_${i} \]/,/\[/p" /ca.conf | sed '$d' >> "/tmp/${i}.conf"
    elif grep -q "subjectAltName = @alt_names" "/tmp/${i}.conf"; then
      sed -n "/\[ alt_names \]/,/\[/p" /ca.conf | sed '$d' >> "/tmp/${i}.conf"
    fi
  else
    # Use default extensions if no specific section exists
    cat >> "/tmp/${i}.conf" << EOF
[ alt_names ]
DNS.1 = kubernetes
DNS.2 = ${i}
EOF
  fi

  # Generate CSR using the temporary config
  openssl req -new -key "/certs/${i}.key" -sha256 \
    -config "/tmp/${i}.conf" \
    -out "/certs/${i}.csr"

  # Sign the certificate
  openssl x509 -req -days 3653 -in "/certs/${i}.csr" \
    -sha256 -CA "/certs/ca.crt" \
    -CAkey "/certs/ca.key" \
    -CAcreateserial \
    -out "/certs/${i}.crt"
    
  # Clean up the temporary config
  rm "/tmp/${i}.conf"
done

# Set version for packages
VERSION=${CERT_VERSION:-"1.0.0"}
PACKAGE_TYPE=${PACKAGE_TYPE:-"deb"}

# Create package directories
echo "Creating package directories..."

# CA certificates package
PKG_DIR_CA="/tmp/kubernetes-ca-certs_${VERSION}"
mkdir -p ${PKG_DIR_CA}/etc/kubernetes/pki
cp /certs/ca.crt ${PKG_DIR_CA}/etc/kubernetes/pki/
cp /certs/ca.key ${PKG_DIR_CA}/etc/kubernetes/pki/
chmod 600 ${PKG_DIR_CA}/etc/kubernetes/pki/ca.key

# API Server certificates package
PKG_DIR_API="/tmp/kubernetes-apiserver-certs_${VERSION}"
mkdir -p ${PKG_DIR_API}/etc/kubernetes/pki
cp /certs/kube-api-server.crt ${PKG_DIR_API}/etc/kubernetes/pki/apiserver.crt
cp /certs/kube-api-server.key ${PKG_DIR_API}/etc/kubernetes/pki/apiserver.key
chmod 600 ${PKG_DIR_API}/etc/kubernetes/pki/apiserver.key

# Controller Manager certificates package
PKG_DIR_CM="/tmp/kubernetes-controller-manager-certs_${VERSION}"
mkdir -p ${PKG_DIR_CM}/etc/kubernetes/pki
cp /certs/kube-controller-manager.crt ${PKG_DIR_CM}/etc/kubernetes/pki/controller-manager.crt
cp /certs/kube-controller-manager.key ${PKG_DIR_CM}/etc/kubernetes/pki/controller-manager.key
chmod 600 ${PKG_DIR_CM}/etc/kubernetes/pki/controller-manager.key

# Scheduler certificates package
PKG_DIR_SCHED="/tmp/kubernetes-scheduler-certs_${VERSION}"
mkdir -p ${PKG_DIR_SCHED}/etc/kubernetes/pki
cp /certs/kube-scheduler.crt ${PKG_DIR_SCHED}/etc/kubernetes/pki/scheduler.crt
cp /certs/kube-scheduler.key ${PKG_DIR_SCHED}/etc/kubernetes/pki/scheduler.key
chmod 600 ${PKG_DIR_SCHED}/etc/kubernetes/pki/scheduler.key

# Proxy certificates package
PKG_DIR_PROXY="/tmp/kubernetes-proxy-certs_${VERSION}"
mkdir -p ${PKG_DIR_PROXY}/etc/kubernetes/pki
cp /certs/kube-proxy.crt ${PKG_DIR_PROXY}/etc/kubernetes/pki/kube-proxy.crt
cp /certs/kube-proxy.key ${PKG_DIR_PROXY}/etc/kubernetes/pki/kube-proxy.key
chmod 600 ${PKG_DIR_PROXY}/etc/kubernetes/pki/kube-proxy.key

# Service Account certificates package
PKG_DIR_SA="/tmp/kubernetes-service-account-certs_${VERSION}"
mkdir -p ${PKG_DIR_SA}/etc/kubernetes/pki
cp /certs/service-accounts.crt ${PKG_DIR_SA}/etc/kubernetes/pki/sa.crt
cp /certs/service-accounts.key ${PKG_DIR_SA}/etc/kubernetes/pki/sa.key
chmod 600 ${PKG_DIR_SA}/etc/kubernetes/pki/sa.key

# Node certificates packages
for node in "node-0" "node-1"; do
  PKG_DIR_NODE="/tmp/kubernetes-${node}-certs_${VERSION}"
  mkdir -p ${PKG_DIR_NODE}/var/lib/kubelet
  cp /certs/${node}.crt ${PKG_DIR_NODE}/var/lib/kubelet/kubelet.crt
  cp /certs/${node}.key ${PKG_DIR_NODE}/var/lib/kubelet/kubelet.key
  cp /certs/ca.crt ${PKG_DIR_NODE}/var/lib/kubelet/ca.crt
  chmod 600 ${PKG_DIR_NODE}/var/lib/kubelet/kubelet.key
done

# Create DEBIAN directories and control files for each package
for pkg in "kubernetes-ca-certs" "kubernetes-apiserver-certs" "kubernetes-controller-manager-certs" \
           "kubernetes-scheduler-certs" "kubernetes-proxy-certs" "kubernetes-service-account-certs" \
           "kubernetes-node-0-certs" "kubernetes-node-1-certs"; do
  
  PKG_DIR="/tmp/${pkg}_${VERSION}"
  mkdir -p ${PKG_DIR}/DEBIAN
  
  # Create control file
  cat > ${PKG_DIR}/DEBIAN/control << EOF
Package: ${pkg}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: ${PKG_MAINTAINER}
Description: Kubernetes TLS certificates for ${pkg}
EOF

  # Create postinst script to set permissions
  cat > ${PKG_DIR}/DEBIAN/postinst << EOF
#!/bin/bash
echo "${pkg} certificates have been installed."
# Set proper permissions for private keys
find /etc/kubernetes/pki -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true
find /var/lib/kubelet -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true
EOF
  chmod 755 ${PKG_DIR}/DEBIAN/postinst
done

# Build the packages
echo "Building packages..."
for pkg in "kubernetes-ca-certs" "kubernetes-apiserver-certs" "kubernetes-controller-manager-certs" \
           "kubernetes-scheduler-certs" "kubernetes-proxy-certs" "kubernetes-service-account-certs" \
           "kubernetes-node-0-certs" "kubernetes-node-1-certs"; do
  
  PKG_DIR="/tmp/${pkg}_${VERSION}"
  
  if [ "$PACKAGE_TYPE" = "deb" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    # Create the Debian package
    echo "Building Debian package for ${pkg}..."
    if touch -d "@${SOURCE_DATE_EPOCH}" "${PKG_DIR}" >/dev/null 2>&1; then
      find "${PKG_DIR}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
    fi
    dpkg-deb --root-owner-group --build ${PKG_DIR} "/output/${pkg}_${VERSION}_${DEB_ARCH}.deb"
    echo "Debian package created: /output/${pkg}_${VERSION}_${DEB_ARCH}.deb"
  fi
  
  if [ "$PACKAGE_TYPE" = "rpm" ] || [ "$PACKAGE_TYPE" = "all" ]; then
    # Create RPM packages
    echo "Building RPM package for ${pkg}..."
    
    # Create RPM build directory structure
    RPM_BUILD_DIR="/tmp/rpmbuild-${pkg}"
    mkdir -p ${RPM_BUILD_DIR}/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    
    # Create a tarball of the package contents
    TARBALL_DIR="/tmp/${pkg}-${VERSION}"
    mkdir -p ${TARBALL_DIR}
    
    # Copy all files from the Debian package directory to the tarball directory
    cp -r ${PKG_DIR}/* ${TARBALL_DIR}/ 2>/dev/null || true
    # Remove DEBIAN directory as it's not needed for RPM
    rm -rf ${TARBALL_DIR}/DEBIAN
    
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
      -czf ${RPM_BUILD_DIR}/SOURCES/${pkg}-${VERSION}.tar.gz ${pkg}-${VERSION}
    
    # Create the spec file
    cat > ${RPM_BUILD_DIR}/SPECS/${pkg}.spec << EOF
Name:           ${pkg}
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Kubernetes TLS certificates for ${pkg}
License:        ${PKG_LICENSE}
URL:            ${PKG_URL}
Source0:        ${pkg}-${VERSION}.tar.gz
BuildArch:      ${RPM_ARCH}

%description
Kubernetes TLS certificates for ${pkg}

%prep
%setup -q

%install
mkdir -p %{buildroot}/
cp -r * %{buildroot}/

%files
EOF

    # Add all files to the spec file
    find ${PKG_DIR} -type f -not -path "*/DEBIAN/*" | while read file; do
      rel_path=${file#${PKG_DIR}/}
      if [[ $rel_path == *".key" ]]; then
        echo "%attr(600, root, root) /${rel_path}" >> ${RPM_BUILD_DIR}/SPECS/${pkg}.spec
      else
        echo "%attr(644, root, root) /${rel_path}" >> ${RPM_BUILD_DIR}/SPECS/${pkg}.spec
      fi
    done
    
    # Add post install script
    cat >> ${RPM_BUILD_DIR}/SPECS/${pkg}.spec << EOF
%post
echo "${pkg} certificates have been installed."
# Set proper permissions for private keys
find /etc/kubernetes/pki -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true
find /var/lib/kubelet -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true

%changelog
* ${BUILD_DATE} ${PKG_MAINTAINER} - ${VERSION}-1
- Initial package
EOF

    # Build the RPM package
    rpmbuild \
      --define "_topdir ${RPM_BUILD_DIR}" \
      --define "_buildhost k8s-release" \
      --define "source_date_epoch ${SOURCE_DATE_EPOCH}" \
      --define "use_source_date_epoch_as_buildtime 1" \
      --define "clamp_mtime_to_source_date_epoch 1" \
      -bb ${RPM_BUILD_DIR}/SPECS/${pkg}.spec
    
    # Copy the RPM to the output directory
    find ${RPM_BUILD_DIR}/RPMS -name "*.rpm" -exec cp {} /output/ \;
    
    # Verify the RPM package exists
    RPM_FILE=$(find /output -name "${pkg}-${VERSION}*.rpm")
    if [ -n "${RPM_FILE}" ]; then
      echo "RPM package successfully created at ${RPM_FILE}"
    else
      echo "ERROR: RPM package creation failed for ${pkg}!"
    fi
  fi
done

# Ensure the output directory is accessible
chmod -R 777 /output

echo "Certificate packages created:"
ls -la /output/
