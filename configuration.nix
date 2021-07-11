{ config, pkgs, ... }:
{
  imports = [
    <home-manager/nixos>
    ./hardware-configuration.nix

    ./audio.nix
    ./boot.nix
    ./crypto.nix
    ./gui.nix
    ./network.nix
    ./yubi.nix

    ./root.nix
    ./nixpulvis.nix
  ];

  # TODO: Factor out the pukak spesific configs.

  time.timeZone = "America/New_York";
  environment.pathsToLink = [ "/libexec" ];
  services.printing.enable = true;
  programs.mtr.enable = true;

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  # };

  environment.systemPackages = with pkgs; [
    home-manager
    git
    zip
    vim
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?
}
