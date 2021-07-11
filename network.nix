{ config, pkgs, ... }:
{
  # TODO: Define your hostname from hardware imports.
  networking.hostName = "masva";
  networking.nameservers = ["1.1.1.1"];
  networking.networkmanager.enable = true;
  services.avahi.enable = true;
}
