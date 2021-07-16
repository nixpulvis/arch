{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.gui;
in {
  options = {
    gui = {
      enable = mkEnableOption "graphical user interface";

      sway = mkOption {
        default = false;
        type = with types; bool;
        description = "sway Wayland window manager";
      };

      i3 = mkOption {
        default = true;
        type = with types; bool;
        description = "i3 X11 window manager";
      };

      sddm = mkOption {
        default = true;
        type = with types; bool;
        description = "SDDM login manager";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      fonts.fontconfig.enable = true;
      fonts.fonts = with pkgs; [
        fira
        fira-mono
        noto-fonts
        noto-fonts-cjk
        noto-fonts-emoji
      ];
    })

    (mkIf (cfg.enable && cfg.sddm) {
      services.xserver = {
        enable = true;
        layout = "us";
        xkbOptions = "ctrl:nocaps";
        libinput = {
          enable = true;
          touchpad.clickMethod = "none";
          touchpad.tapping = false;
          touchpad.disableWhileTyping = true;
        };
      };
    })

    (mkIf cfg.i3 {
      services.xserver.windowManager.i3.enable = true;
    })

    (mkIf cfg.sddm {
      services.xserver.displayManager.sddm.enable = true;
    })

    (mkIf cfg.sway {
      programs.sway.enable = true;
    }) 
  ];
}
