#!/bin/bash
set -euo pipefail
trap 'echo "Error: command failed at line $LINENO"; exit 1' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
QEMU_DIR="$SCRIPT_DIR/../externals/QEMU/build/"

# repack rootfs.cpio
command -v fakeroot >/dev/null
fakeroot -- sh -c '
set -eu
cd rootfs
mkdir -p dev
cleanup() {
    rm -f dev/console dev/tty dev/ttyS0 dev/ttyAMA0 dev/null dev/zero dev/random dev/urandom dev/ashmem dev/ion
}
trap cleanup EXIT
cleanup
mknod -m 600 dev/console c 5 1
mknod -m 666 dev/tty c 5 0
mknod -m 660 dev/ttyS0 c 4 64
mknod -m 666 dev/null c 1 3
mknod -m 666 dev/zero c 1 5
mknod -m 666 dev/random c 1 8
mknod -m 666 dev/urandom c 1 9
# This kernel registers the real ashmem misc device as minor 0x7f.
mknod -m 666 dev/ashmem c 10 127
mknod -m 666 dev/ion c 10 126
find . | cpio -o -H newc --owner root:root > ../rootfs_patched.cpio
'

# start qemu. 
if [ -x "$QEMU_DIR/qemu-system-aarch64" ]; then
    QEMU_BIN="$QEMU_DIR/qemu-system-aarch64"
    QEMU_DATA_DIR="$QEMU_DIR/qemu-bundle/usr/local/share/qemu"
fi

QEMU_GDB_ARGS=()
if [ -n "${QEMU_GDB_PORT:-}" ]; then
    QEMU_GDB_ARGS+=( -gdb "tcp::${QEMU_GDB_PORT}" )
fi
KASLR_OPT="nokaslr"
if [ "${QEMU_KASLR:-0}" = "1" ]; then
    KASLR_OPT=""
fi

# signal=off keeps Ctrl-C in the serial pane from killing QEMU.
# hung_task_panic is compiled in; KernelSnitch spray on TCG exceeds the
# 120s hung-task window and would otherwise panic the guest.
SERIAL_LOG="${QEMU_SERIAL_LOG:-$SCRIPT_DIR/serial.log}"
exec "$QEMU_BIN" \
    -L "$QEMU_DATA_DIR" \
    -machine virt,ram-base=0x40000000 \
    -cpu cortex-a76 \
    -smp 8 \
    -m 8G \
    -kernel "$SCRIPT_DIR/kernel" \
    -initrd "$SCRIPT_DIR/rootfs_patched.cpio" \
    -append "rdinit=/init console=ttyAMA0 earlycon=pl011,mmio,0x09000000 keep_bootcon loglevel=3 ${KASLR_OPT} panic=-1 hung_task_panic=0 hung_task_timeout_secs=0" \
    -nographic \
    -no-reboot \
    -monitor none \
    -chardev "stdio,id=char0,signal=off,logfile=${SERIAL_LOG},logappend=on" \
    -serial chardev:char0 \
    "${QEMU_GDB_ARGS[@]}"
