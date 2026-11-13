#!/bin/bash
# Liga a ponte das conquistas ao vivo (ejs_cheevos.c) num RetroArch do EmulatorJS já no commit certo.
#   bash retroarch-cheevos.sh <pasta do RetroArch> <pasta desta receita>
# Depois, compile com EJS_CHEEVOS=1 no ambiente (o Makefile.emulatorjs ajustado lê essa variável).
# Usado pelo build.sh daqui e pelos builds do cabo (gambatte, mgba, handhelds), que montam esta pasta em /cheevos.
set -euo pipefail
ra=${1:?RetroArch}
here=${2:?receita}
tr -d '\r' < "$here/ejs_cheevos.c" > "$ra/emulatorjs/ejs_cheevos.c"
tr -d '\r' < "$here/patch-retroarch.py" > /tmp/patch-cheevos.py
(cd "$ra" && python3 /tmp/patch-cheevos.py)
