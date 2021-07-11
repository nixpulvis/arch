{ config, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ yubico-pam ];
  services.udev.packages = [pkgs.yubikey-personalization];
  security.pam.yubico = {
    enable = true;
    mode = "challenge-response";
  };
}
