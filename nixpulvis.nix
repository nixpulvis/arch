{ config, pkgs, ... }:
{
  users.users.nixpulvis = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    shell = pkgs.fish;
  };

  # TODO: Use from submodule and link after activation.
  # home-manager.users.nixpulvis = import ./home.nix;
}
