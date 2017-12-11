#!/bin/fish

# Setup the locale for the US.
sed -i 's/#\(en_US\.UTF-8\)/\1/' /etc/locale.gen
locale-gen

# We live in the Mountains... for now.
# TODO: Make this an option.
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Fish is our shell.
usermod -s /usr/bin/fish root

# Create root's home directory.
cp -aT /etc/skel/ /root/
chmod 700 /root

# TODO: This is probably wrong, and should be removed. but maybe ok for the
# live installation.
sed -i 's/#\(PermitRootLogin \).\+/\1yes/' /etc/ssh/sshd_config

sed -i "s/#Server/Server/g" /etc/pacman.d/mirrorlist
sed -i 's/#\(Storage=\)auto/\1volatile/' /etc/systemd/journald.conf

# TODO: Test these.
sed -i 's/#\(HandleSuspendKey=\)suspend/\1ignore/' /etc/systemd/logind.conf
sed -i 's/#\(HandleHibernateKey=\)hibernate/\1ignore/' /etc/systemd/logind.conf
sed -i 's/#\(HandleLidSwitch=\)suspend/\1ignore/' /etc/systemd/logind.conf

# TODO: This should only be used for the live install. Full installations
# should setup pacman once at install time.
systemctl enable pacman-init.service
systemctl set-default multi-user.target

