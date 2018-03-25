#!/bin/bash

export PATH="bin:$PATH"
export PERL6LIB="lib"
export ARCHVAULT_ADMIN_NAME="live"
export ARCHVAULT_ADMIN_PASS="your admin user's password"
export ARCHVAULT_SFTP_NAME="variable"
export ARCHVAULT_SFTP_PASS="your sftp user's password"
export ARCHVAULT_GRUB_NAME="grub"
export ARCHVAULT_GRUB_PASS="your grub user's password"
export ARCHVAULT_ROOT_PASS="your root password"
export ARCHVAULT_VAULT_NAME="vault"
export ARCHVAULT_VAULT_PASS="your LUKS encrypted volume's password"
export ARCHVAULT_HOSTNAME="vault"
export ARCHVAULT_PARTITION="/dev/sdb"
export ARCHVAULT_PROCESSOR="other"
export ARCHVAULT_GRAPHICS="intel"
export ARCHVAULT_DISK_TYPE="usb"
export ARCHVAULT_LOCALE="en_US"
export ARCHVAULT_KEYMAP="us"
export ARCHVAULT_TIMEZONE="America/Los_Angeles"
archvault new
