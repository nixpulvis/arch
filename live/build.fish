#!/bin/fish

# Base installation, plus needed packages (airootfs)
setarch x86_64 mkarchiso -v init
setarch x86_64 mkarchiso -v -p "haveged intel-ucode memtest86+ mkinitcpio-nfs-utils nbd zsh" install

# Additional packages (airootfs)
#setarch x86_64 mkarchiso -v -p "$(grep -h -v ^# ${script_path}/packages.txt)" install

# Needed packages for x86_64 EFI boot
setarch x86_64 mkarchiso -v -p "efitools" install

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
#local _hook
#mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
#mkdir -p ${work_dir}/${arch}/airootfs/etc/initcpio/install
#for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
#    cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/hooks
#    cp /usr/lib/initcpio/install/${_hook} ${work_dir}/${arch}/airootfs/etc/initcpio/install
#done
#sed -i "s|/usr/lib/initcpio/|/etc/initcpio/|g" ${work_dir}/${arch}/airootfs/etc/initcpio/install/archiso_shutdown
#cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/${arch}/airootfs/etc/initcpio/install
#cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/${arch}/airootfs/etc/initcpio
#cp ${script_path}/mkinitcpio.conf ${work_dir}/${arch}/airootfs/etc/mkinitcpio-archiso.conf
#gnupg_fd=
#if [[ ${gpg_key} ]]; then
#  gpg --export ${gpg_key} >${work_dir}/gpgkey
#  exec 17<>${work_dir}/gpgkey
#fi
#ARCHISO_GNUPG_FD=${gpg_key:+17} setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux -g /boot/archiso.img' run
#if [[ ${gpg_key} ]]; then
#  exec 17<&-
#fi

# Customize installation (airootfs)
# TODO: Fix this to use new customize_airootfs path.
#cp -af ${script_path}/airootfs ${work_dir}/${arch}
#curl -o ${work_dir}/${arch}/airootfs/etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=all&protocol=http&use_mirror_status=on'
#lynx -dump -nolist 'https://wiki.archlinux.org/index.php/Installation_Guide?action=render' >> ${work_dir}/${arch}/airootfs/root/install.txt
#setarch ${arch} mkarchiso ${verbose} -w "${work_dir}/${arch}" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r '/root/customize_airootfs.sh' run
#rm ${work_dir}/${arch}/airootfs/root/customize_airootfs.sh

# Prepare kernel/initramfs ${install_dir}/boot/
#mkdir -p ${work_dir}/iso/${install_dir}/boot/${arch}
#cp ${work_dir}/${arch}/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/${arch}/archiso.img
#cp ${work_dir}/${arch}/airootfs/boot/vmlinuz-linux ${work_dir}/iso/${install_dir}/boot/${arch}/vmlinuz

# Add other aditional/extra files to ${install_dir}/boot/
#cp ${work_dir}/${arch}/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
#cp ${work_dir}/${arch}/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
#cp ${work_dir}/${arch}/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
#cp ${work_dir}/${arch}/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE

# Prepare /${install_dir}/boot/syslinux
#mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
#for _cfg in ${script_path}/syslinux/*.cfg; do
#    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
#         s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
#done
#cp ${script_path}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
#cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
#cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
#cp ${work_dir}/${arch}/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
#mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
#gzip -c -9 ${work_dir}/${arch}/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
#gzip -c -9 ${work_dir}/${arch}/airootfs/usr/lib/modules/*-ARCH/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz

# Prepare /isolinux
mkdir -p work/iso/isolinux
sed "s|%INSTALL_DIR%|arch|g" isolinux/isolinux.cfg > work/iso/isolinux/isolinux.cfg
cp work/airootfs/usr/lib/syslinux/bios/isolinux.bin work/iso/isolinux/
cp work/airootfs/usr/lib/syslinux/bios/isohdpfx.bin work/iso/isolinux/
cp work/airootfs/usr/lib/syslinux/bios/ldlinux.c32 work/iso/isolinux/

# Prepare /EFI
#mkdir -p ${work_dir}/iso/EFI/boot
#cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/PreLoader.efi ${work_dir}/iso/EFI/boot/bootx64.efi
#cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/HashTool.efi ${work_dir}/iso/EFI/boot/
#
#cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/iso/EFI/boot/loader.efi
#
#mkdir -p ${work_dir}/iso/loader/entries
#cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
#cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/iso/loader/entries/
#cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/iso/loader/entries/
#
#sed "s|%ARCHISO_LABEL%|${iso_label}|g;
#     s|%INSTALL_DIR%|${install_dir}|g" \
#    ${script_path}/efiboot/loader/entries/archiso-x86_64-usb.conf > ${work_dir}/iso/loader/entries/archiso-x86_64.conf
#
## EFI Shell 2.0 for UEFI 2.3+
#curl -o ${work_dir}/iso/EFI/shellx64_v2.efi https://raw.githubusercontent.com/tianocore/edk2/master/ShellBinPkg/UefiShell/X64/Shell.efi
## EFI Shell 1.0 for non UEFI 2.3+
#curl -o ${work_dir}/iso/EFI/shellx64_v1.efi https://raw.githubusercontent.com/tianocore/edk2/master/EdkShellBinPkg/FullShell/X64/Shell_Full.efi

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
#mkdir -p ${work_dir}/iso/EFI/archiso
#truncate -s 64M ${work_dir}/iso/EFI/archiso/efiboot.img
#mkfs.fat -n ARCHISO_EFI ${work_dir}/iso/EFI/archiso/efiboot.img
#
#mkdir -p ${work_dir}/efiboot
#mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot
#
#mkdir -p ${work_dir}/efiboot/EFI/archiso
#cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
#cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img
#
#cp ${work_dir}/iso/${install_dir}/boot/intel_ucode.img ${work_dir}/efiboot/EFI/archiso/intel_ucode.img
#
#mkdir -p ${work_dir}/efiboot/EFI/boot
#cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/PreLoader.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
#cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/HashTool.efi ${work_dir}/efiboot/EFI/boot/
#
#cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/efiboot/EFI/boot/loader.efi
#
#mkdir -p ${work_dir}/efiboot/loader/entries
#cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
#cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/efiboot/loader/entries/
#cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/efiboot/loader/entries/
#
#sed "s|%ARCHISO_LABEL%|${iso_label}|g;
#     s|%INSTALL_DIR%|${install_dir}|g" \
#    ${script_path}/efiboot/loader/entries/archiso-x86_64-cd.conf > ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
#
#cp ${work_dir}/iso/EFI/shellx64_v2.efi ${work_dir}/efiboot/EFI/
#cp ${work_dir}/iso/EFI/shellx64_v1.efi ${work_dir}/efiboot/EFI/
#
#umount -d ${work_dir}/efiboot

# Build airootfs filesystem image
#cp -a -l -f ${work_dir}/${arch}/airootfs ${work_dir}
#setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
#setarch ${arch} mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" ${gpg_key:+-g ${gpg_key}} prepare
#rm -rf ${work_dir}/airootfs
# rm -rf ${work_dir}/${arch}/airootfs (if low space, this helps)

# Build ISO
mkarchiso -v iso arch.iso

