# Bifrost Bridge — documentation build targets
#
# Usage:
#   make diagrams          build all .mmd → .png
#   make diagram-FOO       build documentation/diagrams/FOO.mmd only
#   make whitepaper              build whitepaperV1.pdf
#   make docs              build everything (diagrams first, then PDFs)
#   make clean             remove generated images and PDFs

MMDC       := mmdc
PANDOC     := pandoc
MERMAID_FILTER := ./node_modules/.bin/mermaid-filter

DIAG_DIR   := documentation/diagrams
IMG_DIR    := documentation/images
DOC_DIR    := documentation

MMD_SRCS   := $(wildcard $(DIAG_DIR)/*.mmd)
MMD_PNGS   := $(patsubst $(DIAG_DIR)/%.mmd,$(IMG_DIR)/%.png,$(MMD_SRCS))

WHITEPAPER := $(DOC_DIR)/whitepaperV1.pdf

HEADER_TEX   := $(DOC_DIR)/header.tex
GIT_INFO_TEX := $(DOC_DIR)/.git-info.tex

GIT_REV    := $(shell git rev-parse --short HEAD)
GIT_DATE   := $(shell git log -1 --format=%ad --date=short)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)

PANDOC_FLAGS := --pdf-engine=xelatex \
  --from=markdown+tex_math_single_backslash \
  --filter=$(MERMAID_FILTER) \
  --resource-path=$(DOC_DIR) \
  --highlight-style=tango \
  --include-in-header=$(GIT_INFO_TEX) \
  --include-in-header=$(HEADER_TEX) \
  -V geometry:margin=2.5cm \
  -V mainfont="DejaVu Serif" \
  -V monofont="DejaVu Sans Mono" \
  -V fontsize=11pt

# ── Phony targets ──────────────────────────────────────────────

.PHONY: docs diagrams whitepaper clean git-info

docs: diagrams whitepaper

diagrams: $(MMD_PNGS)

whitepaper: $(WHITEPAPER)

git-info:
	@printf '\\newcommand{\\gitRev}{%s}\n\\newcommand{\\gitDate}{%s}\n\\newcommand{\\gitBranch}{%s}\n' \
	  '$(GIT_REV)' '$(GIT_DATE)' '$(GIT_BRANCH)' > $(GIT_INFO_TEX)

clean:
	rm -f $(MMD_PNGS) $(WHITEPAPER) $(GIT_INFO_TEX) mermaid-filter.err

# ── Pattern rules ──────────────────────────────────────────────

$(IMG_DIR)/%.png: $(DIAG_DIR)/%.mmd | $(IMG_DIR)
	$(MMDC) -i $< -o $@ -b white -s 4

$(WHITEPAPER): $(DOC_DIR)/technical_documentation.md $(MMD_PNGS) $(MERMAID_FILTER) $(HEADER_TEX) git-info | $(IMG_DIR)
	$(PANDOC) $(PANDOC_FLAGS) -o $@ $<

$(MERMAID_FILTER): package.json
	npm install
	@touch $@

$(IMG_DIR):
	mkdir -p $@

# ── Convenience aliases (make diagram-utxo_flow) ─

diagram-%: $(IMG_DIR)/%.png
	@true
