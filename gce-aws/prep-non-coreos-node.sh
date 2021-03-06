#!/bin/bash

# Prerequisites for CoreOS Self-Hosted Kubernetes Install

# Self-hosted Kubernetes install requires several things:

# * systemd, etcd, flannel, docker and rkt
# * SSH, port 443 and port 2379 opened on each host
# * a user named "core" with passwordless sudo permissions
# * the CoreOS kubelet-wrapper script placed in /usr/lib/coreos

# In addition you will need SELinux, if it's in use, set to 
# permissive mode or disabled to allow rkt to run pods.  This script 
# will automate these changes.

# This script should be run as root or using sudo.

# If systemd isn't there, die immediately

if ! $(systemd-analyze 2>&1 > /dev/null); then
  echo "Kubernetes self-hosted install is only supported with systemd."
  exit 1
fi

# Set some variables to default values

MANUAL_FLANNEL=0

LNPATH="/usr/bin/ln"

CLEANUP_LIST=""

COREOS_ENV_FILE=${COREOS_ENV_FILE:-/var/coreos/metadata}
COREOS_ENV_DIR=$(dirname $COREOS_ENV_FILE)
BOOTKUBE_ENV_FILE=${BOOTKUBE_ENV_FILE:-${COREOS_ENV_DIR}/metadata-bootkube.conf}


# Are we on RHEL 7, Ubuntu 16, CoreOS or something unsupported?

if [ -f /etc/os-release ]; then
  source <(cat /etc/os-release)
  OS_NAME=$ID
  OS_VER_MAJOR=${VERSION_ID%.*}
else
  echo "Your distribution does not have an /etc/os-release file, which means it's unsupported for Kubernetes self-hosted install."
  exit 1
fi

case $OS_NAME in
  rhel)
    if [ "$OS_VER_MAJOR" != "7" ]; then 
      echo "Your version of RHEL is not supported for Kubernetes self-hosted install."
      exit 1
    else
      PKG_INSTALL="yum install"
      PKG_LIST="docker etcd flannel https://dl.fedoraproject.org/pub/epel/7/x86_64/j/jq-1.5-1.el7.x86_64.rpm https://dl.fedoraproject.org/pub/epel/7/x86_64/o/oniguruma-5.9.5-3.el7.x86_64.rpm"
      rpm --import http://download.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
      # Persistently set SELinux to non-enforcing
      # TODO: do we need to turn AppArmor off on Ubuntu?
      setenforce 0
      if [ -f /etc/sysconfig/selinux ] && $(grep -q "SELINUX=enforcing" /etc/sysconfig/selinux); then
        sed -i.bak -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/sysconfig/selinux
      fi
    fi
    ;;
  ubuntu)
    if [ "$OS_VER_MAJOR" != "16" ]; then
      echo "Your version of Ubuntu is not supported for Kubernetes self-hosted install."
      exit 1
    else
      PKG_INSTALL="apt-get install"
      PKG_LIST="docker.io etcd jq"
      MANUAL_FLANNEL="1"
      LNPATH="/bin/ln"
    fi
    ;;
  coreos)
    echo "You don't need to run this script against a version of CoreOS that's "
    echo "supported for self-install."
    exit 0
    ;;
  *)
    echo "Your distribution is not supported for Kubernetes self-hosted install."
    exit 1
    ;;
esac

# Pull the metadata from GCE or AWS

if [ $(curl -ss --connect-timeout 1 -f -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/id") ]; then
  COREOS_OEM="gce"
elif [ $(curl -ss --connect-timeout 1 -f http://169.254.169.254/latest/meta-data/ami-id) ]; then
  COREOS_OEM="ec2"
else
  echo "Your cloud provider, if any, is not (yet) supported by this script."
  exit 1
fi

case $COREOS_OEM in
  gce)
    COREOS_PUBLIC_IPV4=$(curl -ss -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    COREOS_PRIVATE_IPV4=$(curl -ss -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
    ;;
  ec2)    
    COREOS_PUBLIC_IPV4=$(curl -ss http://169.254.169.254/latest/meta-data/public-ipv4)
    COREOS_PRIVATE_IPV4=$(curl -ss http://169.254.169.254/latest/meta-data/local-ipv4)
    ;;
esac

# Write out metadata for the self-install script to use

mkdir -p $COREOS_ENV_DIR
mkdir -p $(dirname $BOOTKUBE_ENV_FILE)
echo "COREOS_PUBLIC_IPV4=${COREOS_PUBLIC_IPV4}" > $BOOTKUBE_ENV_FILE
echo "COREOS_PRIVATE_IPV4=${COREOS_PRIVATE_IPV4}" >> $BOOTKUBE_ENV_FILE
echo "LNPATH=${LNPATH}" >> $BOOTKUBE_ENV_FILE
cat $COREOS_ENV_DIR/metadata-*.conf > $COREOS_ENV_FILE

# Install etcd, docker, flannel and jq

$PKG_INSTALL -y $PKG_LIST

# Ubuntu auto-starts etcd on package install.  Why??

if systemctl status etcd > /dev/null; then
  systemctl stop etcd && systemctl disable etcd
fi

# Ubuntu also auto-starts docker on package install.  We stop but don't 
# disable.

if systemctl status docker > /dev/null; then
  systemctl stop docker
fi

# Red Hat changes the default flannel network config prefix, so if we 
# detect that, we change it back to keep cross-distro compatibility

if [ -f /etc/sysconfig/flanneld ]; then
  sed -i.bak -e 's/FLANNEL_ETCD_KEY=\"\/atomic.io\/network\"/FLANNEL_ETCD_KEY=\"\/coreos.com\/network\"/' /etc/sysconfig/flanneld
fi

if [ "$MANUAL_FLANNEL" -eq "1" ]; then
  # We have to do a tarball flannel install for Ubuntu because there are 
  # no flannel .debs we trust out there
  FLANNEL_VER="0.5.5"
  FLANNEL_RELEASE_URL="https://github.com/coreos/flannel/releases/download/v${FLANNEL_VER}/flannel-${FLANNEL_VER}-linux-amd64.tar.gz"

  FLANNEL_UNIT="[Unit]
Description=Network fabric for containers
Documentation=https://github.com/coreos/flannel
After=etcd.service etcd2.service
Before=docker.service

[Service]
Type=notify
Restart=always
RestartSec=5
Environment=\"TMPDIR=/var/tmp/\"
EnvironmentFile=-/run/flannel/options.env
ExecStartPre=/bin/mkdir -p /run/flannel
ExecStart=/usr/bin/flanneld
ExecStartPost=/usr/bin/mk-docker-opts.sh -d /run/flannel/flannel_docker_opts.env -c

[Install]
WantedBy=multi-user.target"

  FLANNEL_DOCKER_OPTS_DROPIN="[Service]
EnvironmentFile=-/run/flannel/flannel_docker_opts.env"

  curl -ss -L $FLANNEL_RELEASE_URL > flannel-${FLANNEL_VER}-linux-amd64.tar.gz
  tar zxvf flannel-${FLANNEL_VER}-linux-amd64.tar.gz
  cp flannel-${FLANNEL_VER}/flanneld /usr/local/bin
  cp flannel-${FLANNEL_VER}/mk-docker-opts.sh /usr/local/bin
  $LNPATH -sf /usr/local/bin/flanneld /usr/bin
  $LNPATH -sf /usr/local/bin/mk-docker-opts.sh /usr/bin
  echo "$FLANNEL_UNIT" > /etc/systemd/system/flanneld.service
  mkdir -p /etc/systemd/system/docker.service.d
  echo "$FLANNEL_DOCKER_OPTS_DROPIN" > /etc/systemd/system/docker.service.d/10-flannel-opts.conf
  systemctl daemon-reload
  CLEANUP_LIST="$CLEANUP_LIST flannel-${FLANNEL_VER}-linux-amd64.tar.gz flannel-${FLANNEL_VER}"
fi

# Make the required host firewall changes.  We assume SSH is allowed by 
# default.

OS_FIREWALL="iptables" # fallback if we don't detect anything else

if $(systemctl status firewalld > /dev/null); then
  OS_FIREWALL="firewalld"
fi

if $(systemctl status ufw > /dev/null); then
  OS_FIREWALL="ufw"
fi

case $OS_FIREWALL in
  firewalld)
    firewall-cmd --add-service https && firewall-cmd --add-port 2379/tcp && firewall-cmd --runtime-to-permanent
    ;;
  ufw)
    ufw allow proto tcp to $COREOS_PRIVATE_IPV4 port 443,2379 comment 'Added by Kubernetes self-hosted install'
    ;;
  *)
    if ! $(iptables -L INPUT -n | grep ACCEPT | grep -q 443); then
      # We want to insert the iptables rule after the last ACCEPT rule 
      # -- this should work for most rule sets, and if not, the user 
      # will need to modify this script to suit.
      IPTABLES_ACCEPT_LINE=$(( $(iptables -L INPUT -n --line-numbers | grep ACCEPT | tail -n 1 | cut -d" " -f1) + 1 ))
      iptables -I INPUT $IPTABLES_ACCEPT_LINE -m comment --comment 'Added by Kubernetes self-hosted install' -p tcp -m multiport --dports 443,2379 -j ACCEPT
    fi
    ;;
esac

# Some basic user setup:

# If the core user doesn't exist, create it.

if ! $(id core > /dev/null); then
  useradd -m core
fi

# If the user has no .ssh directory, create it

if ! [ -d ~core/.ssh ]; then
  sudo -u core mkdir -p ~core/.ssh
  sudo -u core chmod go-rwx ~core/.ssh
fi

# If the core user has no SSH authorized_keys, copy ours if it exists

if ! [ -f ~core/.ssh/authorized_keys ]; then
  if [ -f ~/.ssh/authorized_keys ]; then
    cat ~/.ssh/authorized_keys | sudo -u core sh -c "cat - >> ~core/.ssh/authorized_keys"
    sudo -u core chmod go-rwx ~core/.ssh/authorized_keys
  fi
fi

# If the core user doesn't have passwordless sudo, add that.

if ! $(sudo -l -U core | grep -q "NOPASSWD: ALL"); then 
  echo "core ALL=NOPASSWD: ALL" >> /etc/sudoers.d/core
fi

# Install rkt

export RKT_VER="v1.9.1"
export RKT_USER="core"
export RKT_S1_DIR="/usr/lib/rkt/stage1-images"
export RKT_RELEASE_URL="https://github.com/coreos/rkt/releases/download/${RKT_VER}/rkt-${RKT_VER}.tar.gz"

groupadd rkt
groupadd rkt-admin
usermod -a -G rkt,rkt-admin $RKT_USER
curl -ss -L $RKT_RELEASE_URL > rkt-${RKT_VER}.tar.gz
tar zxvf rkt-${RKT_VER}.tar.gz
cp rkt-${RKT_VER}/rkt /usr/local/bin/rkt
ln -sf /usr/local/bin/rkt /usr/bin/rkt

# Some distributions use totally separate /usr/lib and /usr/lib64, some 
# link one to the other, and some just use /usr/lib.

if [ -d /usr/lib64 ]; then
  mkdir -p /usr/lib64/rkt/stage1-images
else
  mkdir -p /usr/lib/rkt/stage1-images
fi
if [ ! -d /usr/lib/rkt ] && [ -d /usr/lib64/rkt ]; then
  ln -s /usr/lib64/rkt /usr/lib/rkt
fi

cp rkt-${RKT_VER}/*.aci ${RKT_S1_DIR}
cp rkt-${RKT_VER}/init/systemd/tmpfiles.d/* /etc/tmpfiles.d
systemd-tmpfiles --create

CLEANUP_LIST="$CLEANUP_LIST rkt-${RKT_VER}.tar.gz rkt-${RKT_VER}"

# TODO: should we pre-trust keys for things?

# Install /usr/lib/coreos/kubelet-wrapper

mkdir -p /usr/lib/coreos

curl -ss https://raw.githubusercontent.com/coreos/coreos-overlay/master/app-admin/kubelet-wrapper/files/kubelet-wrapper > kubelet-wrapper

sed -i -e 's/source=\/usr\/share\/ca-certificates/source=\/etc\/ssl\/certs/;s/source=\/usr\/lib\/os-release/source=\/etc\/os-release/' kubelet-wrapper
mv kubelet-wrapper /usr/lib/coreos
chmod +x /usr/lib/coreos/kubelet-wrapper
CLEANUP_LIST="$CLEANUP_LIST kubelet-wrapper"

# Clean up
rm -rf $CLEANUP_LIST

echo "Modification complete."

