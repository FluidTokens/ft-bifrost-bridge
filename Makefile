# Bifrost Bridge — documentation build targets
#
# Usage:
#   make diagrams          build all .mmd → .png
#   make diagram-FOO       build documentation/diagrams/FOO.mmd only
#   make whitepaper              build whitepaperV1.pdf
#   make docs              build everything (diagrams first, then PDFs)
#   make clean             remove generated images and PDFs

MMDC       := npx -y @mermaid-js/mermaid-cli
PANDOC     := pandoc

DIAG_DIR   := documentation/diagrams
IMG_DIR    := documentation/images
DOC_DIR    := documentation

MMD_SRCS   := $(wildcard $(DIAG_DIR)/*.mmd)
MMD_PNGS   := $(patsubst $(DIAG_DIR)/%.mmd,$(IMG_DIR)/%.png,$(MMD_SRCS))

WHITEPAPER := $(DOC_DIR)/whitepaperV1.pdf

GIT_HASH   := $(shell git rev-parse --short HEAD)

PANDOC_FLAGS := --pdf-engine=xelatex \
  --from=markdown+tex_math_single_backslash \
  --resource-path=$(DOC_DIR) \
  --highlight-style=tango \
  -V geometry:margin=1in \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue \
  -V toccolor=blue \
  -V mainfont="DejaVu Serif" \
  -V monofont="DejaVu Sans Mono" \
  -V fontsize=11pt \
  -V header-includes='\usepackage{fancyhdr}\pagestyle{fancy}\fancyfoot[C]{\thepage}\fancyfoot[R]{\footnotesize $(GIT_HASH)}'

# ── Phony targets ──────────────────────────────────────────────

.PHONY: docs diagrams whitepaper clean

docs: diagrams whitepaper

diagrams: $(MMD_PNGS)

whitepaper: $(WHITEPAPER)

clean:
	rm -f $(MMD_PNGS) $(WHITEPAPER)

# ── Pattern rules ──────────────────────────────────────────────

$(IMG_DIR)/%.png: $(DIAG_DIR)/%.mmd | $(IMG_DIR)
	$(MMDC) -i $< -o $@ -b white -s 4

$(WHITEPAPER): $(DOC_DIR)/technical_documentation.md $(MMD_PNGS) | $(IMG_DIR)
	$(PANDOC) $(PANDOC_FLAGS) -o $@ $<

$(IMG_DIR):
	mkdir -p $@

# ── Convenience aliases (make diagram-utxo_flow) ─

diagram-%: $(IMG_DIR)/%.png
	@true
