#!/bin/bash
set -e

echo "=========================================="
echo "Atyro Cloud Technologies - Ubuntu VM"
echo "=========================================="
echo "RAM: ${RAM}MB | CPU: ${CPU} | DISK: ${DISK}GB"
echo "VNC: http://localhost:6080/vnc.html (Password: ${VNC_PASS})"
echo "SSH: ssh root@localhost -p 2222 (Password: ${ROOT_PASS})"
echo "=========================================="

# Detect KVM
KVM_OPTS=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_OPTS="-enable-kvm -cpu host,kvm=on"
    echo "[KVM] Hardware acceleration ENABLED"
else
    KVM_OPTS="-cpu qemu64"
    echo "[KVM] Not available - using software emulation"
fi

# Create disk on first run
if [ ! -f /vm/disk.qcow2 ]; then
    echo "[DISK] First boot - Creating ${DISK}GB standalone system disk..."
    # Copy Ubuntu image to create a standalone writable disk (no backing file)
    cp /vm/ubuntu.img /vm/disk.qcow2
    qemu-img resize /vm/disk.qcow2 ${DISK}G
    echo "[DISK] System disk created - all data will persist"
else
    echo "[DISK] Using existing persistent system disk"
fi

# Create cloud-init config
cat > /tmp/user-data << USERDATA
#cloud-config
hostname: atyro-vm
users: []

chpasswd:
  expire: false
  users:
    - name: root
      password: ${ROOT_PASS}
      type: text

ssh_pwauth: true
disable_root: false

ssh:
  permit_root_login: true
  password_authentication: true

bootcmd:
  - echo "root:${ROOT_PASS}" | chpasswd

# Install network tools
packages:
  - openssh-server
  - iproute2
  - net-tools
  - iputils-ping
  - curl
  - wget

runcmd:
  - echo "root:${ROOT_PASS}" | chpasswd
  - passwd -u root
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd || systemctl restart ssh

growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
USERDATA

cat > /tmp/meta-data << METADATA
instance-id: atyro-$(date +%s)
local-hostname: atyro-vm
METADATA

# Create cloud-init ISO
xorriso -as mkisofs -output /vm/seed.iso -volid cidata -joliet -rock \
    /tmp/user-data /tmp/meta-data 2>/dev/null

# Setup VNC password
mkdir -p /root/.vnc
echo "${VNC_PASS}" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

echo "[BOOT] Starting VM with optimizations..."

# Start QEMU with maximum performance
exec qemu-system-x86_64 \
  ${KVM_OPTS} \
  -m ${RAM} \
  -smp ${CPU},cores=${CPU},threads=1,sockets=1 \
  -machine type=q35,accel=kvm:tcg \
  -drive file=/vm/disk.qcow2,if=virtio,format=qcow2,cache=writeback,aio=threads,discard=unmap \
  -drive file=/vm/seed.iso,if=virtio,media=cdrom \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -vnc 0.0.0.0:0,password-secret=vncsec \
  -object secret,id=vncsec,data=${VNC_PASS} \
  -smbios type=0,vendor="Atyro Cloud Technologies",version="2.1" \
  -smbios type=1,manufacturer="Atyro Cloud Technologies",product="Atyro Cloud Technologies",version="2.1",family="Atyro Cloud" \
  -smbios type=2,manufacturer="Atyro Cloud Technologies",product="Atyro Cloud Technologies" \
  -smbios type=3,manufacturer="Atyro Cloud Technologies" \
  -device virtio-balloon-pci \
  -device virtio-rng-pci \
  -rtc base=utc,clock=host \
  -serial mon:stdio \
  -boot order=c \
  -name "Atyro-VM"
