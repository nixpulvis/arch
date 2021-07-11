{ config, pkgs, ... }: {
  services.xserver = {
    enable = true;
    layout = "us";
    libinput.enable = true;
    xkbOptions = "ctrl:nocaps";
    displayManager.sddm.enable = true;
    windowManager.i3.enable = true;
  };
  programs.sway.enable = true;

  fonts.fontconfig.enable = true;
  fonts.fonts = with pkgs; [
    fira
    fira-mono
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
  ];
}
