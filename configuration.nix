{ config, pkgs, ... }:
let home-manager = builtins.fetchGit {
  url = "https://github.com/nix-community/home-manager";
  ref = "master";
};
in {
  imports = [
    (import "${home-manager}/nixos")

    ./audio.nix
    ./boot.nix
    ./crypto.nix
    ./gui.nix
    ./network.nix

    ./users/root.nix
    ./users/nixpulvis.nix

    ./hardware/masva.nix
  ];

  time.timeZone = "America/New_York";

  crypto = {
    enable = true;
    yubikey = true;
  };

  gui = {
    enable = true;
    sway = true;
  };

  services.printing.enable = true;
  programs.mtr.enable = true;
  environment.pathsToLink = [ "/libexec" ];

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
