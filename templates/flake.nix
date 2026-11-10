# flake.nix template (rustlikeapro): rust-overlay toolchain from rust-toolchain.toml + crane builds.
# `nix build` → package, `nix flake check` → clippy/fmt/nextest, `nix develop` → dev shell.
# Native installers from this build: see nix-bundle-app in references/ecosystem.md.
{
  description = "myproj";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs"; # One nixpkgs for the whole closure.
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Same toolchain as rustup users get: single source of truth.
        toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        craneLib = (crane.mkLib pkgs).overrideToolchain (_: toolchain);

        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ ]; # e.g. pkgs.openssl, pkgs.wayland
        };

        # Dependencies built once and cached; rebuilt only when Cargo.lock changes.
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        myproj = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          doCheck = false; # Tests run in `checks.nextest`.
        });
      in
      {
        packages.default = myproj;

        checks = {
          inherit myproj;
          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--workspace --all-targets --all-features -- -D warnings";
          });
          fmt = craneLib.cargoFmt { inherit src; };
          nextest = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system}; # Inherits build inputs of every check.
          packages = with pkgs; [
            cargo-nextest
            cargo-deny
            cargo-hack
            just
            typos
          ];
        };
      });
}
