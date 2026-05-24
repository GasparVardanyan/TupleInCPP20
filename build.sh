#!/usr/bin/env bash

pandoc  tuple-in-cpp20.md  -o  tuple-in-cpp20.pdf                 --pdf-engine=xelatex  --from=gfm  -H  header.tex                  --lua-filter  minted-wrap.lua  --no-highlight
pandoc  tuple-in-cpp20.md  -o  tuple-in-cpp20_SolarizedDark.pdf   --pdf-engine=xelatex  --from=gfm  -H  header-solarized-dark.tex   --lua-filter  minted-wrap.lua  --no-highlight
pandoc  tuple-in-cpp20.md  -o  tuple-in-cpp20_SolarizedLight.pdf  --pdf-engine=xelatex  --from=gfm  -H  header-solarized-light.tex  --lua-filter  minted-wrap.lua  --no-highlight
