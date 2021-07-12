{ config, pkgs, ... }:
{
  users.users.nixpulvis = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    shell = pkgs.fish;
  };
}
