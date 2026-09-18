#!/bin/bash
# The lib volume on the node's instance store: the first block device of model
# "Amazon EC2 NVMe Instance Storage", formatted as xfs labelled lib unless it
# carries that label already (the store keeps its data over a reboot, never over
# a stop or a replacement). var-lib.mount mounts /dev/disk/by-label/lib. A size
# with several devices gets the first; without one the unit fails naming the
# disks present, and local-fs.target with it.
set -euo pipefail

model="Amazon EC2 NVMe Instance Storage"
device=""
for _ in $(seq 30); do
  device=$(lsblk -dno PATH,MODEL | awk -v model="$model" 'index($0, model) { print $1; exit }')
  [ -n "$device" ] && break
  sleep 1
done
if [ -z "$device" ]; then
  echo "no instance store on this instance; the disks are:" >&2
  lsblk -dno PATH,SIZE,MODEL >&2
  exit 1
fi
if [ "$(blkid -s LABEL -o value "$device" || true)" = lib ]; then
  echo "$device carries the lib filesystem already"
  exit 0
fi
mkfs.xfs -f -L lib "$device"
udevadm trigger "$device"
udevadm settle
echo "$device formatted as the lib volume"
