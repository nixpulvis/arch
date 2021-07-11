{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.crypto;
in {
  options = {
    crypto = {
      enable = mkEnableOption "general security and crypto configuration";
      yubikey = mkOption {
        default = false;
        type = with types; bool;
        description = "yubikey support";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.openssh.enable = true;
      programs.ssh.startAgent = false;
      programs.gnupg.agent = {
        enable = true;
        pinentryFlavor = "gtk2";
        enableSSHSupport = true;
      };
    })

    (mkIf cfg.yubikey {
      environment.systemPackages = with pkgs; [ yubico-pam ];
      services.udev.packages = [pkgs.yubikey-personalization];
      security.pam.yubico = {
        enable = true;
        mode = "challenge-response";
      };
    })
  ];
}
