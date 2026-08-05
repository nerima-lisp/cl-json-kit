{
  description = "Dependency-free, SBCL-first JSON library for Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # `inputs.nixpkgs.follows` is mandatory on every input: without it each one
    # drags in its own nixpkgs, inflating flake.lock and rebuilding the same
    # derivations.

    # The org flake preset. Everything this file used to spell out by hand --
    # the `.asd` version extraction, `forAllSystems`, the treefmt eval wired to
    # both `formatter` and `checks.formatting`, the mkdocs package plus its
    # check, the run-tests.lisp gate and the `apps.test`/`apps.default` pair --
    # is the single `mkPackageFlake` call below, so none of it can drift from
    # the other 20 repositories.
    #
    # Pinned to a release TAG, never to a branch: a bare
    # `github:nerima-lisp/cl-nix-forge` follows that repository's default
    # branch, so an upstream push to main would change this build without
    # warning.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-nix-forge,
      cl-weave,
      treefmt-nix,
    }:
    let
      lib = nixpkgs.lib;

      # x86_64-linux is what CI gates; aarch64-darwin is the development
      # machine. Every per-system output -- packages, checks, apps AND devShells
      # -- comes from this one list, so leaving aarch64-darwin out takes `nix
      # build` and `nix develop` off the development machine as well. That trade
      # was made on 2026-08-01 and reverted on 2026-08-02; aarch64-darwin carries
      # no CI gate, which PACKAGE_STANDARD.md's "systems" section accepts
      # explicitly. aarch64-linux and x86_64-darwin are nobody's verification and
      # are not declared.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    # `mkPackageFlake` spans systems -- it obtains a `pkgs` and its own
    # cl-nix-forge instance per entry in `systems` -- so the per-system `lib`
    # this function is taken from contributes nothing but the function itself.
    cl-nix-forge.lib.${builtins.head systems}.mkPackageFlake {
      inherit self systems nixpkgs;

      pname = "cl-json-kit";

      # Single source of truth for the package version: the `:version` form in
      # cl-json-kit.asd. A release only ever edits the .asd file and every
      # derivation carrying a version -- the package, the docs site, and both
      # store paths -- follows automatically. There is deliberately no
      # `version` argument to pass.
      asd = ./cl-json-kit.asd;

      # Spelled out rather than left to `mkPackageFlake`'s documented default
      # of `self`, because that default does not evaluate: a flake's `self` is
      # an attrset with an `outPath`, and `lib.fileset` refuses string-like
      # values. `./.` is the same directory as a path literal. `self` is still
      # what the preset hands the treefmt gate, which wants the UNFILTERED tree
      # and takes a store path happily.
      root = ./.;

      meta = {
        description = "Dependency-free JSON reader and writer for Common Lisp strings and character streams";
        homepage = "https://github.com/nerima-lisp/cl-json-kit";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      };

      # cl-weave is a dependency of `cl-json-kit/test` and of nothing else (see
      # cl-json-kit.asd), so it is a CHECK dependency: it must not enter the
      # library's closure or the overlay's `pkgs.cl-json-kit`. These are BUILT
      # DERIVATIONS, never CL_SOURCE_REGISTRY strings -- assembling that
      # registry is cl-nix-forge's job and it does it transitively, which is
      # what replaces the hand-rolled `"${cl-weave}//:${self}//"` this file
      # used to thread through the check, the app and the devShell separately.
      #
      # `packages.*.cl-weave` is cl-weave's ASDF SYSTEM, built by cl-weave's
      # own flake -- a different output from its `packages.*.default`, which is
      # the delivered CLI. Taking the system means the consumer never compiles
      # cl-weave itself.
      #
      # Do NOT reach for `fromDerivation` on the flake input instead, here or
      # for the next sibling dependency added to this list: that puts
      # cl-weave's uncompiled SOURCE on the registry, and ASDF then tries to
      # write its fasls next to those sources, inside the read-only Nix store.
      lispCheckDependencies = ctx: [ cl-weave.packages.${ctx.system}.cl-weave ];

      # Drives BOTH `checks.default` and `apps.test`, from this one number, so
      # the command a contributor runs by hand and the gate CI runs cannot
      # drift apart -- the two `timeout 120` invocations this replaces were
      # separate literals that could.
      timeoutSeconds = 120;

      # docs/mkdocs.yml + docs/src/, built with `--strict` so a broken link or
      # a page missing from the nav is a build failure. Material for MkDocs
      # bundles all of its assets, so the build needs no network access inside
      # the Nix sandbox.
      #
      # `checks.docs` comes with it, and is the point: without that gate the
      # docs are only ever built by the publish workflow, which runs after a
      # merge to main -- meaning such a break is discovered as a failed deploy
      # rather than as a failed pull request.
      docs.root = ./docs;

      # ONE treefmt evaluation drives `nix fmt` and the `checks.formatting`
      # gate, so the formatter and CI can never disagree about what
      # "formatted" means, and any unformatted tracked file fails
      # `nix flake check`. `evalModule` is passed in rather than closed over so
      # this repository picks its own treefmt-nix version. Scope stays the
      # preset's Nix-only default, which is this repo's existing scope and for
      # the same reasons: nixfmt (RFC-style) is a zero-footgun, low-diff
      # formatter, whereas YAML formatters mangle the GitHub Actions `on:` key
      # and Markdown reformatting would churn the whole docs tree.
      treefmt.evalModule = treefmt-nix.lib.evalModule;

      # SBCL with the competitor JSON libraries preloaded, so
      # benchmark/competitors.lisp can compare cl-json-kit against them under
      # `nix develop` (see benchmark/README.md). `mkShell` puts `packages`
      # ahead of everything from `inputsFrom` on PATH, so this wrapped SBCL
      # wins over the plain one the derivation pulls in, and nixpkgs builds the
      # wrapper with `--prefix CL_SOURCE_REGISTRY`, so its libraries are
      # prepended to the shell's registry rather than replacing it.
      #
      # cl-weave is deliberately NOT named here. `mkPackageFlake` builds its
      # dev shell from the CHECK-ENABLED derivation, so `lispCheckDependencies`
      # are already on that shell's registry -- which is what makes `nix
      # develop` followed by `sbcl --script run-tests.lisp`, the loop
      # docs/src/project/development.md documents, work at all. Repeating cl-weave
      # here would be a second source of truth for it.
      devShellPackages = ctx: [
        (ctx.pkgs.sbcl.withPackages (ps: [
          ps.jzon
          ps.jonathan
          ps.jsown
          ps.yason
        ]))
      ];
    };
}
