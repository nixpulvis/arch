{ config, pkgs, ... }:
{
  users.users.root = {
    isNormalUser = false;
  };

  home-manager.users.root = {
    programs.vim = {
      enable = true;
      plugins = with pkgs.vimPlugins; [vim-nix];
    };
  };
}
