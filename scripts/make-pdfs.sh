

# Process markdown to PDF using pandoc with mermaid filter
pandoc documentation/technical_documentation.md \
  --pdf-engine=xelatex \
  --from=markdown+tex_math_single_backslash \
  --highlight-style=tango \
  -V geometry:margin=1in \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue \
  -V toccolor=blue \
  -V mainfont="DejaVu Serif" \
  -V monofont="DejaVu Sans Mono" \
  -V fontsize=11pt \
  -o documentation/whitepaperV1.pdf
