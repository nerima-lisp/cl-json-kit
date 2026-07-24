{
  description = "Dependency-free, SBCL-only JSON library for Common Lisp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v0.10.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      cl-weave,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      sourceRegistry = "${cl-weave}//:${self}//";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          cl-json-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-json-kit";
            version = "0.1.0";
            src = self;
            systems = [ "cl-json-kit" ];
          };
          default = cl-json-kit;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default =
            pkgs.runCommand "cl-json-kit-tests"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                timeout 120 sbcl --script ${self}/run-tests.lisp
                touch "$out/passed"
              '';
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          test = pkgs.writeShellApplication {
            name = "cl-json-kit-test";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.coreutils
            ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              exec timeout 120 sbcl --script ${self}/run-tests.lisp
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-json-kit-test";
          };
          test = {
            type = "app";
            program = "${test}/bin/cl-json-kit-test";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # SBCL with the competitor JSON libraries preloaded, so
          # benchmark/competitors.lisp can compare cl-json-kit against them
          # under `nix develop` (see benchmark/README.md).
          benchmarkSbcl = pkgs.sbcl.withPackages (
            ps: [
              ps.jzon
              ps.jonathan
              ps.jsown
              ps.yason
            ]
          );
        in
        {
          default = pkgs.mkShell {
            packages = [ benchmarkSbcl ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
