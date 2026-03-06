# Bifrost Bridge — documentation build targets
#
# Usage:
#   make diagrams          build all .mmd → .png
#   make diagram-FOO       build documentation/diagrams/FOO.mmd only
#   make pdfs              build all markdown → PDF
#   make pdf-technical     build technical_documentation.pdf only
#   make docs              build everything (diagrams first, then PDFs)
#   make clean             remove generated images and PDFs

MMDC       := npx -y @mermaid-js/mermaid-cli
PANDOC     := pandoc

DIAG_DIR   := documentation/diagrams
IMG_DIR    := documentation/images
DOC_DIR    := documentation

MMD_SRCS   := $(wildcard $(DIAG_DIR)/*.mmd)
MMD_PNGS   := $(patsubst $(DIAG_DIR)/%.mmd,$(IMG_DIR)/%.png,$(MMD_SRCS))

MD_SRCS    := $(wildcard $(DOC_DIR)/*.md)
PDFS       := $(patsubst $(DOC_DIR)/%.md,$(DOC_DIR)/%.pdf,$(MD_SRCS))

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
  -V fontsize=11pt

# ── Phony targets ──────────────────────────────────────────────

.PHONY: docs diagrams pdfs clean

docs: diagrams pdfs

diagrams: $(MMD_PNGS)

pdfs: $(PDFS)

clean:
	rm -f $(MMD_PNGS) $(PDFS)

# ── Pattern rules ──────────────────────────────────────────────

$(IMG_DIR)/%.png: $(DIAG_DIR)/%.mmd | $(IMG_DIR)
	$(MMDC) -i $< -o $@ -b white -s 4

$(DOC_DIR)/%.pdf: $(DOC_DIR)/%.md $(MMD_PNGS) | $(IMG_DIR)
	$(PANDOC) $(PANDOC_FLAGS) -o $@ $<

$(IMG_DIR):
	mkdir -p $@

# ── Convenience aliases (make diagram-utxo_flow, make pdf-technical_documentation) ─

diagram-%: $(IMG_DIR)/%.png
	@true

pdf-%: $(DOC_DIR)/%.pdf
	@true
