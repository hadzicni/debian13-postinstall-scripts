#!/bin/bash
set -Eeuo pipefail

echo "=== Debian 13 Minimal Template Prep ==="

# Root check
[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

echo "Cleaning package cache..."
apt clean

echo "Removing temporary files..."
rm -rf /tmp/*
rm -rf /var/tmp/*

echo "Clearing logs..."
journalctl --rotate
journalctl --vacuum-time=1s

echo "Resetting machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "Removing SSH host keys..."
rm -f /etc/ssh/ssh_host_*

echo "Removing shell history..."
rm -f /root/.bash_history
rm -f /home/*/.bash_history 2>/dev/null || true

echo
echo "=== Template ready ==="
echo "Shutdown and convert to template"
