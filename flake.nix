{
  description = "Freespin: a native replacement for Logi Options+ on macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        freespinctl = pkgs.callPackage ./nix/package.nix { };
        default = freespinctl;
      });

      homeManagerModules = rec {
        freespin = import ./nix/hm-module.nix self;
        default = freespin;
      };
    };
}
