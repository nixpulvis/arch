{ config, pkgs, ... }:
{
  imports = [
    <home-manager/nixos>
    ./hardware-configuration.nix

    ./root.nix
    ./nixpulvis.nix
  ];

  # TODO: Factor out the pukak spesific configs.

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/New_York";

  environment.pathsToLink = [ "/libexec" ];

  # TODO: Define your hostname from hardware imports.
  networking.hostName = "masva";
  networking.nameservers = ["1.1.1.1"];
  networking.networkmanager.enable = true;
  services.avahi.enable = true;

  services.xserver = {
    enable = true;
    layout = "us";
    libinput.enable = true;
    xkbOptions = "ctrl:nocaps";
    displayManager.sddm.enable = true;
    displayManager.defaultSession = "none+i3";
    windowManager.i3.enable = true;
    # desktopManager.wallpaper.mode = "fill";
    # desktopManager.wallpaper.combineScreens = true;
  };

  programs.sway.enable = true;

  sound.enable = true;
  hardware.pulseaudio.enable = true;

  fonts.fontconfig.enable = true;
  fonts.fonts = with pkgs; [
    fira
    fira-mono
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
  ];

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  # };

  services.openssh.enable = true;
  services.printing.enable = true;
  services.udev.packages = [pkgs.yubikey-personalization];

  environment.systemPackages = with pkgs; [
    home-manager
    yubico-pam
  ];

  programs.mtr.enable = true;
  programs.ssh.startAgent = false;
  programs.gnupg.agent = {
    enable = true;
    pinentryFlavor = "gtk2";
    enableSSHSupport = true;
  };

  security.pam.yubico = {
    enable = true;
    mode = "challenge-response";
  };

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
