import Lake
open Lake DSL

package BifrostProofs where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

require Blaster from git
  "https://github.com/input-output-hk/Lean-blaster" @ "main"

@[default_target]
lean_lib BifrostProofs where
  srcDir := "."
