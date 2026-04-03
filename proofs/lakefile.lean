import Lake
open Lake DSL

package BifrostProofs where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib BifrostProofs where
  srcDir := "."
