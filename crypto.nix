{ config, pkgs, ... }:
{
  services.openssh.enable = true;
  programs.ssh.startAgent = false;
  programs.gnupg.agent = {
    enable = true;
    pinentryFlavor = "gtk2";
    enableSSHSupport = true;
  };
}
