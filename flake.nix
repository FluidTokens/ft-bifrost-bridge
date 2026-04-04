{
  description = "Bifrost Bridge flake with development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , flake-utils
    , nixpkgs
    , ...
    } @ inputs:
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        jdk = pkgs.openjdk25;
        sbt = pkgs.sbt.override { jre = jdk; };
        visualvm = pkgs.visualvm.override { jdk = jdk; };
      in
      rec {
        devShell = pkgs.mkShell {
          # This fixes bash prompt/autocomplete issues with subshells (i.e. in VSCode) under `nix develop`/direnv
          buildInputs = [ pkgs.bashInteractive ];
          packages = with pkgs; [
            git
            jdk
            sbt
            visualvm
            aiken
            nixpkgs-fmt
            nodejs
            nodePackages.mermaid-cli
            texliveFull
            pandoc
            elan
            z3
          ];
          shellHook = ''
            echo ""
            echo "Bifrost Bridge dev shell"
            echo ""
            echo "  Documentation (make):"
            echo "    make docs                       — build everything (diagrams + PDFs)"
            echo "    make diagrams                   — build all .mmd → .png"
            echo "    make whitepaper                 — build whitepaperV1.pdf"
            echo "    make diagram-<name>             — build single diagram (e.g. diagram-utxo_flow)"
            echo "    make clean                      — remove generated images and PDFs"
            echo ""
            echo "  Lean 4 (elan):"
            echo "    elan default leanprover/lean4:v4.24.0  — set Lean toolchain"
            echo "    lake build                              — build Lean project"
            echo ""
          '';
        };
      })
    );

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
  };
}
