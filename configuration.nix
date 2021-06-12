{ config, pkgs, ... }:
{
  imports = [
    <home-manager/nixos>
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/New_York";

  # TODO: Define your hostname from hardware imports.
  networking.hostName = "pukak";
  networking.interfaces.enp7s0.useDHCP = true;
  networking.nameservers = ["1.1.1.1"];

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

  # TODO: Wayland support then remove this eventually.
  services.xserver = {
    enable = true;
    libinput.enable = true;
    layout = "us";
    # xkbOptions = "";  # TODO: map caps to esc.
    displayManager.session = [
      {
        manage = "desktop";
        name = "xsession";
        start = ''exec $HOME/.xsession'';
      }
    ];
  };

  services.openssh.enable = true;
  services.printing.enable = true;
  services.udev.packages = [pkgs.yubikey-personalization];

  environment.systemPackages = with pkgs; [
    home-manager
  ];

  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    pinentryFlavor = "curses";
    enableSSHSupport = true;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  users.users.root = {
    isNormalUser = false;
  };

  home-manager.users.root = {
    programs.vim = {
      enable = true;
      plugins = with pkgs.vimPlugins; [vim-nix];
    };
  };

  users.users.nixpulvis = {
    isNormalUser = true;
    extraGroups = ["wheel"];
  };

  # TODO: Use from submodule and link after activation.
  # home-manager.users.nixpulvis = import ./home.nix;


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?
}
