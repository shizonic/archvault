use v6;
unit module Holovault::Bootstrap;

sub bootstrap() is export
{
    setup();
    mkdisk();
    pacstrap-base();
    configure-users();
    genfstab();
    set-hostname();
    set-nameservers();
    set-locale();
    set-keymap();
    set-timezone();
    set-hwclock();
    configure-tmpfiles();
    configure-pacman();
    configure-system-sleep();
    configure-modprobe();
    generate-initramfs();
    install-bootloader();
    configure-sysctl();
    configure-hidepid();
    configure-securetty();
    configure-iptables();
    enable-systemd-services();
    disable-btrfs-cow();
    augment() if $Holovault::CONF.augment;
    unmount();
}

sub setup()
{
    # initialize pacman-keys
    run qw<haveged -w 1024>;
    run qw<pacman-key --init>;
    run qw<pacman-key --populate archlinux>;
    run qw<pkill haveged>;

    # fetch dependencies needed prior to pacstrap
    my Str @deps = qw<
        arch-install-scripts
        base-devel
        btrfs-progs
        expect
        gptfdisk
        iptables
        kbd
        reflector
    >;
    run qw<pacman -Sy --needed --noconfirm>, @deps;

    # use readable font
    run qw<setfont Lat2-Terminus16>;

    # rank mirrors
    rename '/etc/pacman.d/mirrorlist', '/etc/pacman.d/mirrorlist.bak';
    run qw<
        reflector
        --threads 3
        --protocol https
        --fastest 8
        --save /etc/pacman.d/mirrorlist
    >;
}

# secure disk configuration
sub mkdisk()
{
    # partition disk
    sgdisk();

    # create vault
    mkvault();

    # create and mount btrfs volumes
    mkbtrfs();

    # create boot partition
    mkbootpart();
}

# partition disk with gdisk
sub sgdisk(Str:D :$partition = $Holovault::CONF.partition)
{
    # erase existing partition table
    # create 2MB EF02 BIOS boot sector
    # create 128MB sized partition for /boot
    # create max sized partition for LUKS encrypted volume
    run qw<
        sgdisk
        --zap-all
        --clear
        --mbrtogpt
        --new=1:0:+2M
        --typecode=1:EF02
        --new=2:0:+128M
        --typecode=2:8300
        --new=3:0:0
        --typecode=3:8300
    >, $partition;
}

# create vault with cryptsetup
sub mkvault(
    Str:D :$partition = $Holovault::CONF.partition,
    Str:D :$vault-name = $Holovault::CONF.vault-name
)
{
    # target partition for vault
    my Str $partition-vault = $partition ~ "3";

    # load kernel modules for cryptsetup
    run qw<modprobe dm_mod dm-crypt>;

    # was LUKS encrypted volume password given in cmdline flag?
    if my Str $vault-pass = $Holovault::CONF.vault-pass
    {
        # make LUKS encrypted volume without prompt for vault password
        shell "expect <<'EOF'
                    spawn cryptsetup --cipher aes-xts-plain64 \\
                                     --key-size 512           \\
                                     --hash sha512            \\
                                     --iter-time 5000         \\
                                     --use-random             \\
                                     --verify-passphrase      \\
                                     luksFormat $partition-vault
                    expect \"Are you sure*\" \{ send \"YES\r\" \}
                    expect \"Enter*\" \{ send \"$vault-pass\r\" \}
                    expect \"Verify*\" \{ send \"$vault-pass\r\" \}
                    expect eof
               EOF";

        # open vault without prompt for vault password
        shell "expect <<'EOF'
                    spawn cryptsetup luksOpen $partition-vault $vault-name
                    expect \"Enter*\" \{ send \"$vault-pass\r\" \}
                    expect eof
               EOF";
    }
    else
    {
        loop
        {
            # hacky output to inform user of password entry
            # context until i can implement advanced expect
            # cryptsetup luksFormat program output interception
            say 'Creating LUKS vault...';

            # create LUKS encrypted volume, prompt user for
            # vault password
            my Proc $cryptsetup-luks-format =
                shell "expect -c 'spawn cryptsetup \\
                                        --cipher aes-xts-plain64 \\
                                        --key-size 512           \\
                                        --hash sha512            \\
                                        --iter-time 5000         \\
                                        --use-random             \\
                                        --verify-passphrase      \\
                                        luksFormat $partition-vault;
                                    expect \"Are you sure*\" \{
                                    send \"YES\r\"
                                    \};
                                    interact;
                                    catch wait result;
                                    exit [lindex \$result 3]'";

            # loop until passphrases match
            # - returns exit code 0 if success
            # - returns exit code 1 if SIGINT
            # - returns exit code 2 if wrong password
            last if $cryptsetup-luks-format.exitcode == 0;
        }

        loop
        {
            # hacky output to inform user of password entry
            # context until i can implement advanced expect
            # cryptsetup luksOpen program output interception
            say 'Opening LUKS vault...';

            # open vault with prompt for vault password
            my Proc $cryptsetup-luks-open =
                shell "cryptsetup luksOpen $partition-vault $vault-name";

            # loop until passphrase works
            # - returns exit code 0 if success
            # - returns exit code 1 if SIGINT
            # - returns exit code 2 if wrong password
            last if $cryptsetup-luks-open.exitcode == 0;
        }
    }
}

# create and mount btrfs volumes on open vault
sub mkbtrfs(Str:D :$vault-name = $Holovault::CONF.vault-name)
{
    # create btrfs filesystem on opened vault
    run qqw<mkfs.btrfs /dev/mapper/$vault-name>;

    # mount main btrfs filesystem on open vault
    mkdir '/mnt2';
    run qqw<
        mount
        -t btrfs
        -o rw,noatime,nodiratime,compress=lzo,space_cache
        /dev/mapper/$vault-name
        /mnt2
    >;

    # create btrfs subvolumes
    chdir '/mnt2';
    run qw<btrfs subvolume create @>;
    run qw<btrfs subvolume create @home>;
    run qw<btrfs subvolume create @opt>;
    run qw<btrfs subvolume create @srv>;
    run qw<btrfs subvolume create @tmp>;
    run qw<btrfs subvolume create @usr>;
    run qw<btrfs subvolume create @var>;
    chdir '/';

    # mount btrfs subvolumes, starting with root / ('')
    my Str @btrfs-dirs = '', 'home', 'opt', 'srv', 'tmp', 'usr', 'var';
    for @btrfs-dirs -> $btrfs-dir
    {
        mkdir "/mnt/$btrfs-dir";
        run qqw<
            mount
            -t btrfs
            -o rw,noatime,nodiratime,compress=lzo,space_cache,subvol=@$btrfs-dir
            /dev/mapper/$vault-name
            /mnt/$btrfs-dir
        >;
    }

    # unmount /mnt2 and remove
    run qw<umount /mnt2>;
    '/mnt2'.IO.rmdir;
}

# create and mount boot partition
sub mkbootpart(Str:D :$partition = $Holovault::CONF.partition)
{
    # target partition for boot
    my Str $partition-boot = $partition ~ 2;

    # create ext2 boot partition
    run qqw<mkfs.ext2 $partition-boot>;

    # mount ext2 boot partition in /mnt/boot
    mkdir '/mnt/boot';
    run qqw<mount $partition-boot /mnt/boot>;
}

# bootstrap initial chroot with pacstrap
sub pacstrap-base()
{
    # base packages
    my Str @packages-base = qw<
        abs
        arch-install-scripts
        base
        base-devel
        bash-completion
        btrfs-progs
        ca-certificates
        cronie
        dhclient
        dialog
        dnscrypt-proxy
        ed
        ethtool
        expect
        gptfdisk
        grub-bios
        haveged
        iproute2
        iptables
        iw
        kbd
        kexec-tools
        net-tools
        openresolv
        openssh
        python2
        reflector
        rsync
        sshpass
        systemd-swap
        tmux
        unzip
        wget
        wireless_tools
        wpa_actiond
        wpa_supplicant
        zip
        zsh
    >;

    # https://www.archlinux.org/news/changes-to-intel-microcodeupdates/
    push @packages-base, 'intel-ucode' if $Holovault::CONF.processor eq 'intel';

    # download and install packages with pacman in chroot
    run qw<pacstrap /mnt>, @packages-base;
}

# secure user configuration
sub configure-users()
{
    # updating root password...
    my Str $root-pass-digest = $Holovault::CONF.root-pass-digest;
    run qqw<arch-chroot /mnt usermod -p $root-pass-digest root>;

    # creating new user with password from secure password digest...
    my Str $user-name = $Holovault::CONF.user-name;
    my Str $user-pass-digest = $Holovault::CONF.user-pass-digest;
    run qqw<
        arch-chroot
        /mnt
        useradd
        -m
        -p $user-pass-digest
        -s /bin/bash
        -g users
        -G audio,games,log,lp,network,optical,power,scanner,storage,video,wheel
        $user-name
    >;

    my Str $sudoers = qq:to/EOF/;
    $user-name ALL=(ALL) ALL
    EOF
    spurt '/mnt/etc/sudoers', $sudoers, :append;
}

sub genfstab()
{
    shell 'genfstab -U -p /mnt >> /mnt/etc/fstab';
}

sub set-hostname()
{
    spurt '/mnt/etc/hostname', $Holovault::CONF.host-name;
}

sub set-nameservers()
{
    my Str $resolv-conf-head = q:to/EOF/;
    # DNSCrypt
    options edns0
    nameserver 127.0.0.1

    # OpenDNS nameservers
    nameserver 208.67.222.222
    nameserver 208.67.220.220

    # Google nameservers
    nameserver 8.8.8.8
    nameserver 8.8.4.4
    EOF
    spurt '/mnt/etc/resolv.conf.head', $resolv-conf-head;
}

sub set-locale()
{
    my Str $locale = $Holovault::CONF.locale;

    my Str $sed-cmd =
          q{s,}
        ~ qq{^#\\($locale\\.UTF-8 UTF-8\\)}
        ~ q{,}
        ~ q{\1}
        ~ q{,};
    shell "sed -i '$sed-cmd' /mnt/etc/locale.gen";
    run qw<arch-chroot /mnt locale-gen>;

    my Str $locale-conf = qq:to/EOF/;
    LANG=$locale.UTF-8
    LC_TIME=$locale.UTF-8
    EOF
    spurt '/mnt/etc/locale.conf', $locale-conf;
}

sub set-keymap()
{
    my Str $keymap = $Holovault::CONF.keymap;
    my Str $vconsole = qq:to/EOF/;
    KEYMAP=$keymap
    FONT=Lat2-Terminus16
    FONT_MAP=
    EOF
    spurt '/mnt/etc/vconsole.conf', $vconsole;
}

sub set-timezone()
{
    run qqw<
        arch-chroot
        /mnt
        ln
        -s /usr/share/zoneinfo/{$Holovault::CONF.timezone}
        /etc/localtime
    >;
}

sub set-hwclock()
{
    run qw<arch-chroot /mnt hwclock --systohc --utc>;
}

sub configure-tmpfiles()
{
    # https://wiki.archlinux.org/index.php/Tmpfs#Disable_automatic_mount
    run qw<arch-chroot /mnt systemctl mask tmp.mount>;
    my Str $tmp-conf = q:to/EOF/;
    # see tmpfiles.d(5)
    # always enable /tmp folder cleaning
    D! /tmp 1777 root root 0

    # remove files in /var/tmp older than 10 days
    D /var/tmp 1777 root root 10d

    # namespace mountpoints (PrivateTmp=yes) are excluded from removal
    x /tmp/systemd-private-*
    x /var/tmp/systemd-private-*
    X /tmp/systemd-private-*/tmp
    X /var/tmp/systemd-private-*/tmp
    EOF
    spurt '/mnt/etc/tmpfiles.d/tmp.conf', $tmp-conf;
}

sub configure-pacman()
{
    my Str $sed-cmd = 's/^#\h*\(CheckSpace\|Color\|TotalDownload\)$/\1/';
    shell "sed -i '$sed-cmd' /mnt/etc/pacman.conf";

    $sed-cmd = '';

    $sed-cmd = '/^CheckSpace.*/a ILoveCandy';
    shell "sed -i '$sed-cmd' /mnt/etc/pacman.conf";

    $sed-cmd = '';

    if $*KERNEL.bits == 64
    {
        $sed-cmd = '/^#\h*\[multilib]/,/^\h*$/s/^#//';
        shell "sed -i '$sed-cmd' /mnt/etc/pacman.conf";
    }
}

sub configure-system-sleep()
{
    my Str $sleep-conf = q:to/EOF/;
    [Sleep]
    SuspendMode=mem
    HibernateMode=mem
    HybridSleepMode=mem
    SuspendState=mem
    HibernateState=mem
    HybridSleepState=mem
    EOF
    spurt '/mnt/etc/systemd/sleep.conf', $sleep-conf;
}

sub configure-modprobe()
{
    my Str $modprobe-conf = q:to/EOF/;
    alias floppy off
    blacklist fd0
    blacklist floppy
    blacklist bcma
    blacklist snd_pcsp
    blacklist pcspkr
    blacklist firewire-core
    blacklist thunderbolt
    EOF
    spurt '/mnt/etc/modprobe.d/modprobe.conf', $modprobe-conf;
}

sub generate-initramfs()
{
    # MODULES {{{

    my Str @modules;
    push @modules, $Holovault::CONF.processor eq 'INTEL'
        ?? 'crc32c-intel'
        !! 'crc32c';
    push @modules, 'i915' if $Holovault::CONF.graphics eq 'INTEL';
    push @modules, 'nouveau' if $Holovault::CONF.graphics eq 'NVIDIA';
    push @modules, 'radeon' if $Holovault::CONF.graphics eq 'RADEON';
    push @modules, |qw<lz4 lz4_compress>; # for systemd-swap lz4
    my Str $sed-cmd =
          q{s,}
        ~ q{^MODULES.*}
        ~ q{,}
        ~ q{MODULES=\"} ~ @modules.join(' ') ~ q{\"}
        ~ q{,};
    shell "sed -i '$sed-cmd' /mnt/etc/mkinitcpio.conf";

    # end MODULES }}}

    $sed-cmd = '';

    # HOOKS {{{

    my Str @hooks = qw<
        base
        udev
        autodetect
        modconf
        keyboard
        keymap
        encrypt
        btrfs
        filesystems
        shutdown
        usr
    >;
    $Holovault::CONF.disk-type eq 'USB'
        ?? @hooks.splice(2, 0, 'block')
        !! @hooks.splice(4, 0, 'block');
    $sed-cmd =
          q{s,}
        ~ q{^HOOKS.*}
        ~ q{,}
        ~ q{HOOKS=\"} ~ @hooks.join(' ') ~ q{\"}
        ~ q{,};
    shell "sed -i '$sed-cmd' /mnt/etc/mkinitcpio.conf";

    # end HOOKS }}}

    $sed-cmd = '';

    # FILES {{{

    $sed-cmd = 's,^FILES.*,FILES=\"/etc/modprobe.d/modprobe.conf\",';
    run qqw<sed -i $sed-cmd /mnt/etc/mkinitcpio.conf>;

    # end FILES }}}

    run qw<arch-chroot /mnt mkinitcpio -p linux>;
}

sub install-bootloader()
{
    # GRUB_CMDLINE_LINUX {{{

    my Str $vault-name = $Holovault::CONF.vault-name;
    my Str $vault-uuid = qqx<
        blkid -s UUID -o value {$Holovault::CONF.partition}3
    >.trim;

    my Str $grub-cmdline-linux =
        "cryptdevice=/dev/disk/by-uuid/$vault-uuid:$vault-name"
            ~ ' rootflags=subvol=@';
    $grub-cmdline-linux ~= ' elevator=noop'
        if $Holovault::CONF.disk-type eq 'SSD';
    $grub-cmdline-linux ~= ' radeon.dpm=1'
        if $Holovault::CONF.graphics eq 'RADEON';

    my Str $sed-cmd =
          q{s,}
        ~ q{^\(GRUB_CMDLINE_LINUX\)=.*}
        ~ q{,}
        ~ q{\1=\"} ~ $grub-cmdline-linux ~ q{\"}
        ~ q{,};

    shell "sed -i '$sed-cmd' /mnt/etc/default/grub";

    # end GRUB_CMDLINE_LINUX }}}

    $sed-cmd = '';

    # GRUB_DEFAULT {{{

    $sed-cmd = 's,^\(GRUB_DEFAULT\)=.*,\1=saved,';
    run qqw<sed -i $sed-cmd /mnt/etc/default/grub>;

    # end GRUB_DEFAULT }}}

    $sed-cmd = '';

    # GRUB_SAVEDEFAULT {{{

    $sed-cmd = 's,^#\(GRUB_SAVEDEFAULT\),\1,';
    run qqw<sed -i $sed-cmd /mnt/etc/default/grub>;

    # end GRUB_SAVEDEFAULT }}}

    # GRUB_DISABLE_SUBMENU {{{

    spurt '/mnt/etc/default/grub', 'GRUB_DISABLE_SUBMENU=y', :append;

    # end GRUB_DISABLE_SUBMENU }}}

    run qw<
        arch-chroot
        /mnt
        grub-install
        --target=i386-pc
        --recheck
    >, $Holovault::CONF.partition;
    run qw<
        arch-chroot
        /mnt
        cp
        /usr/share/locale/en@quot/LC_MESSAGES/grub.mo
        /boot/grub/locale/en.mo
    >;
    run qw<
        arch-chroot
        /mnt
        grub-mkconfig
        -o /boot/grub/grub.cfg
    >;
}

sub configure-sysctl()
{
    my Str $sysctl-conf = q:to/EOF/;
    # Configuration file for runtime kernel parameters.
    # See sysctl.conf(5) for more information.

    # Have the CD-ROM close when you use it, and open when you are done.
    #dev.cdrom.autoclose = 1
    #dev.cdrom.autoeject = 1

    # Protection from the SYN flood attack.
    net.ipv4.tcp_syncookies = 1

    # See evil packets in your logs.
    net.ipv4.conf.all.log_martians = 1

    # Enables source route verification
    net.ipv4.conf.default.rp_filter = 1

    # Enable reverse path
    net.ipv4.conf.all.rp_filter = 1

    # Never accept redirects or source routes (these are only useful for routers).
    net.ipv4.conf.all.accept_redirects = 0
    net.ipv4.conf.all.accept_source_route = 0
    net.ipv6.conf.all.accept_redirects = 0
    net.ipv6.conf.all.accept_source_route = 0

    # Disable packet forwarding. Enable for openvpn.
    net.ipv4.ip_forward = 1
    net.ipv6.conf.default.forwarding = 1
    net.ipv6.conf.all.forwarding = 1

    # Ignore ICMP broadcasts
    net.ipv4.icmp_echo_ignore_broadcasts = 1

    # Drop ping packets
    net.ipv4.icmp_echo_ignore_all = 1

    # Protect against bad error messages
    net.ipv4.icmp_ignore_bogus_error_responses = 1

    # Tune IPv6
    net.ipv6.conf.default.router_solicitations = 0
    net.ipv6.conf.default.accept_ra_rtr_pref = 0
    net.ipv6.conf.default.accept_ra_pinfo = 0
    net.ipv6.conf.default.accept_ra_defrtr = 0
    net.ipv6.conf.default.autoconf = 0
    net.ipv6.conf.default.dad_transmits = 0
    net.ipv6.conf.default.max_addresses = 1

    # Increase the open file limit
    #fs.file-max = 65535

    # Allow for more PIDs (to reduce rollover problems);
    # may break some programs 32768
    #kernel.pid_max = 65536

    # Allow for fast recycling of TIME_WAIT sockets. Default value is 0
    # (disabled). Known to cause some issues with hoststated (load balancing
    # and fail over) if enabled, should be used with caution.
    net.ipv4.tcp_tw_recycle = 1
    # Allow for reusing sockets in TIME_WAIT state for new connections when
    # it's safe from protocol viewpoint. Default value is 0 (disabled).
    # Generally a safer alternative to tcp_tw_recycle.
    net.ipv4.tcp_tw_reuse = 1

    # Increase TCP max buffer size setable using setsockopt()
    #net.ipv4.tcp_rmem = 4096 87380 8388608
    #net.ipv4.tcp_wmem = 4096 87380 8388608

    # Increase Linux auto tuning TCP buffer limits
    # min, default, and max number of bytes to use
    # set max to at least 4MB, or higher if you use very high BDP paths
    #net.core.rmem_max = 8388608
    #net.core.wmem_max = 8388608
    #net.core.netdev_max_backlog = 5000
    #net.ipv4.tcp_window_scaling = 1

    # Tweak the port range used for outgoing connections.
    net.ipv4.ip_local_port_range = 2000 65535

    # Tweak those values to alter disk syncing and swap behavior.
    #vm.vfs_cache_pressure = 100
    #vm.laptop_mode = 0
    #vm.swappiness = 60

    # Tweak how the flow of kernel messages is throttled.
    #kernel.printk_ratelimit_burst = 10
    #kernel.printk_ratelimit = 5

    # Reboot 600 seconds after kernel panic or oops.
    #kernel.panic_on_oops = 1
    #kernel.panic = 600

    # Disable SysRq key to avoid console security issues.
    kernel.sysrq = 0
    EOF
    spurt '/mnt/etc/sysctl.conf', $sysctl-conf;

    if $Holovault::CONF.disk-type eq 'SSD'
        || $Holovault::CONF.disk-type eq 'USB'
    {
        my Str $sed-cmd =
              q{s,}
            ~ q{^#\(vm.vfs_cache_pressure\).*}
            ~ q{,}
            ~ q{\1 = 50}
            ~ q{,};
        shell "sed -i '$sed-cmd' /mnt/etc/sysctl.conf";

        $sed-cmd = '';

        $sed-cmd =
              q{s,}
            ~ q{^#\(vm.swappiness\).*}
            ~ q{,}
            ~ q{\1 = 1}
            ~ q{,};
        shell "sed -i '$sed-cmd' /mnt/etc/sysctl.conf";
    }

    run qw<arch-chroot /mnt sysctl -p>;
}

sub configure-hidepid()
{
    my Str $hidepid-conf = q:to/EOF/;
    [Service]
    SupplementaryGroups=proc
    EOF

    my Str $fstab-hidepid = q:to/EOF/;
    # /proc with hidepid (https://wiki.archlinux.org/index.php/Security#hidepid)
    proc                                      /proc       procfs      hidepid=2,gid=proc                                              0 0
    EOF

    mkdir '/mnt/etc/systemd/system/systemd-logind.service.d';
    spurt
        '/mnt/etc/systemd/system/systemd-logind.service.d/hidepid.conf',
        $hidepid-conf;

    spurt '/mnt/etc/fstab', $fstab-hidepid, :append;
}

sub configure-securetty()
{
    my Str $securetty = q:to/EOF/;
    #
    # /etc/securetty
    # https://wiki.archlinux.org/index.php/Security#Denying_console_login_as_root
    #

    console
    #tty1
    #tty2
    #tty3
    #tty4
    #tty5
    #tty6
    #ttyS0
    #hvc0

    # End of file
    EOF
    spurt '/mnt/etc/securetty', $securetty;

    my Str $shell-timeout = q:to/EOF/;
    TMOUT="$(( 60*10 ))";
    [[ -z "$DISPLAY" ]] && export TMOUT;
    case $( /usr/bin/tty ) in
      /dev/tty[0-9]*) export TMOUT;;
    esac
    EOF
    spurt '/mnt/etc/profile.d/shell-timeout.sh', $shell-timeout;
}

sub configure-iptables()
{
    my Str $iptables-test-rules = q:to/EOF/;
    *filter
    #| Allow all loopback (lo0) traffic, and drop all traffic to 127/8 that doesn't use lo0
    -A INPUT -i lo -j ACCEPT
    -A INPUT ! -i lo -d 127.0.0.0/8 -j REJECT
    #| Allow all established inbound connections
    -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    #| Allow all outbound traffic
    -A OUTPUT -j ACCEPT
    #| Allow HTTP and HTTPS connections
    -A INPUT -p tcp --dport 80 -j ACCEPT
    -A INPUT -p tcp --dport 443 -j ACCEPT
    #| Allow SSH connections
    -A INPUT -p tcp -m conntrack --ctstate NEW --dport 22 -j ACCEPT
    #| Allow ZeroMQ connections
    -A INPUT -p tcp -m conntrack --ctstate NEW --dport 4505 -j ACCEPT
    -A INPUT -p tcp -m conntrack --ctstate NEW --dport 4506 -j ACCEPT
    #| Allow NTP connections
    -I INPUT -p udp --dport 123 -j ACCEPT
    -I OUTPUT -p udp --sport 123 -j ACCEPT
    #| Reject pings
    -I INPUT -j DROP -p icmp --icmp-type echo-request
    #| Drop ident server
    -A INPUT -p tcp --dport ident -j DROP
    #| Log iptables denied calls
    -A INPUT -m limit --limit 15/minute -j LOG --log-prefix "[IPT]Dropped input: " --log-level 7
    -A OUTPUT -m limit --limit 15/minute -j LOG --log-prefix "[IPT]Dropped output: " --log-level 7
    #| Reject all other inbound - default deny unless explicitly allowed policy
    -A INPUT -j REJECT
    -A FORWARD -j REJECT
    COMMIT
    EOF
    spurt 'iptables.test.rules', $iptables-test-rules;

    shell 'iptables-save > /mnt/etc/iptables/iptables.up.rules';
    shell 'iptables-restore < iptables.test.rules';
    shell 'iptables-save > /mnt/etc/iptables/iptables.rules';
}

sub enable-systemd-services()
{
    run qw<arch-chroot /mnt systemctl enable cronie>;
    run qw<arch-chroot /mnt systemctl enable dnscrypt-proxy>;
    run qw<arch-chroot /mnt systemctl enable haveged>;
    run qw<arch-chroot /mnt systemctl enable iptables>;
    run qw<arch-chroot /mnt systemctl enable systemd-swap>;
}

sub disable-btrfs-cow()
{
    chattrify('/mnt/var/log/journal', 0o755, 'root', 'systemd-journal');
}

sub chattrify(
    Str $directory,
    # permissions should be octal: https://doc.perl6.org/routine/chmod
    UInt $permissions,
    Str $user,
    Str $group
)
{
    my Str $orig-dir = ~$directory.IO.resolve;
    die 'directory failed exists readable directory test'
        unless $orig-dir.IO.e && $orig-dir.IO.r && $orig-dir.IO.d;

    my Str $backup-dir = $orig-dir ~ '-old';

    rename $orig-dir, $backup-dir;
    mkdir $orig-dir;
    chmod $permissions, $orig-dir;
    run qqw<chattr +C $orig-dir>;
    dir($backup-dir).race.map(-> $file {
        run qqw<cp -dpr --no-preserve=ownership $file $orig-dir>
    });
    run qqw<chown -R $user:$group $orig-dir>;
    run qqw<rm -rf $backup-dir>;
}

# interactive console
sub augment()
{
    # launch fully interactive Bash console, type 'exit' to exit
    shell 'expect -c "spawn /bin/bash; interact"';
}

sub unmount()
{
    shell 'umount /mnt/{boot,home,opt,srv,tmp,usr,var,}';
    my Str $vault-name = $Holovault::CONF.vault-name;
    run qqw<cryptsetup luksClose $vault-name>;
}

# vim: ft=perl6 fdm=marker fdl=0