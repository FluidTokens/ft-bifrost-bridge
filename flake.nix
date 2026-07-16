{
  description = "Bifrost Bridge flake with development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Tracked separately for aiken: 25.11 ships 1.1.19, which has a
    # validation-skipping bug (aiken-lang/aiken#1325, fixed in 1.1.23)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , flake-utils
    , nixpkgs
    , nixpkgs-unstable
    , ...
    } @ inputs:
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgs-unstable = import nixpkgs-unstable { inherit system; };
      in
      rec {
        devShell = pkgs.mkShell {
          # This fixes bash prompt/autocomplete issues with subshells (i.e. in VSCode) under `nix develop`/direnv
          buildInputs = [ pkgs.bashInteractive ];
          packages = with pkgs; [
            git
            pkgs-unstable.aiken
            nixpkgs-fmt
            nodejs
            mermaid-cli
            texliveFull
            pandoc
            elan
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
