Todo
====

- switch from `luks1` to `luks2` cryptsetup format once [GRUB luks2
  support][GRUB luks2 support] ships in a stable release of GRUB
  - likely grub-2.06
- switch `luks2` cryptsetup format from `pbkdf2` to `argon2*` key derival
  function once [libgcrypt argon2 support][libgcrypt argon2 support] ships
  in a stable release of libgcrypt, and [GRUB luks2 argon2 support][GRUB
  luks2 argon2 support] code is shipped in a stable release of GRUB
- replace sudo with [doas][doas]
  - put doas behind cmdline flag
    - `--with-sudo=doas`
- implement mkinitcpio-sshd-nonet
  - new profile: `headless-nonet`
    - disable grub boot encryption
    - pkg https://github.com/atweiden/mkinitcpio-sshd-nonet
    - add systemd config for `ip link set dev eth0 up`
    - modify `sshd_config` to `AllowUsers admin`
    - have systemd launch sshd on startup
- idea: `archvault new [profile]`
  - `archvault new amnesia`
    - https://tails.boum.org/contribute/design/memory_erasure/
  - `archvault new default`
  - `archvault new iso`
  - `archvault new secureboot`
  - use class name variable interpolation
    - `unit role Archvault::Profile`
    - `Archvault::Profile::Amnesia does Archvault::Profile`
    - `Archvault::Profile::Default does Archvault::Profile`
    - `Archvault::Profile::ISO does Archvault::Profile`
    - `Archvault::Profile::SecureBoot does Archvault::Profile`
    - `Archvault::Profile::{$profile}.new`
- idea: add tests
  - qemu
- idea: check for active internet connection
- idea: exception handling
- idea: write progress to TOML file for easier recovery of bootstrap
  - handle being killed by OS because out of memory
    - start section
    - end section
- idea: archvault open/close
  - `archvault open <vaultname> <device>`
    - `archvault open vault /dev/sdb`
  - `archvault close <vaultname>`
    - for when the bootstrap fails
    - `umount /mnt/{boot,home,opt,srv,tmp,usr,var,}`;
    - `cryptsetup luksClose $vaultname`
- idea: exit success/failure messages
- idea: make users double-check config settings in `dialog` menu before
  proceeding with installation
- idea: copytoram
- idea: use ntp
  - `timedatectl set-ntp true`
- idea: grubshift
  - https://github.com/oconnor663/arch/blob/master/grubshift.sh
- consider using:
  - https://github.com/kuerbis/Term-Choose-p6
  - https://github.com/wbiker/io-prompt
  - https://github.com/tadzik/Terminal-ANSIColor

[doas]: https://momi.ca/2020/03/20/doas.html
[GRUB luks2 support]: https://savannah.gnu.org/bugs/?55093
[libgcrypt argon2 support]: https://git.savannah.gnu.org/cgit/grub.git/commit/?id=365e0cc3e7e44151c14dd29514c2f870b49f9755
[GRUB luks2 argon2 support]: https://www.mail-archive.com/grub-devel@gnu.org/msg29535.html
