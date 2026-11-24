{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.shojiwm.url = "github:bea4dev/ShojiWM";
  inputs.shojiwm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, shojiwm, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = {
        cpu-monitor = pkgs.callPackage ./cpu-monitor { };
        meltype = (import ./meltype.nix { inherit pkgs; }).package;
        shoji-bar-4 = (import ./shojiwm.nix { inherit pkgs; }).package;
      };

      nixosConfigurations.inspiron-13-5310 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          shojiwm.nixosModules.default
          ./configuration.nix
        ];
      };
    };
}
