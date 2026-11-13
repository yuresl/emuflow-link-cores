#!/bin/bash
# Compila o fceumm (NES) com o runtime de conquistas (rcheevos + ejs_cheevos.c), nas
# duas variantes que o player usa. Etapa B do RetroAchievements (plano da API, seção 7.2).
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74; Dockerfile nesta pasta):
#   docker run --rm -v emuflow-ppsspp-work:/work -v "<pasta>:/src:ro" -v "<pasta>\out:/out" emuflow-ppsspp-build \
#     bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh"
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
mkdir -p /work/cheevos /out; cd /work/cheevos

[ -d fceumm/.git ] || git clone -q "$FCEUMM_REPO" fceumm
git -C fceumm fetch -q origin
git -C fceumm checkout -q -f "$FCEUMM_COMMIT"
git -C fceumm clean -qfdx
emmake make -C fceumm -j"$(nproc)" -f Makefile.libretro platform=emscripten >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
git -C RetroArch clean -qfdx emulatorjs
tr -d '\r' < /src/ejs_cheevos.c > RetroArch/emulatorjs/ejs_cheevos.c
tr -d '\r' < /src/patch-retroarch.py > /tmp/patch.py
(cd RetroArch && python3 /tmp/patch.py)
cp fceumm/*.bc RetroArch/emulatorjs/

CORES=/work/cheevos/EmulatorJS/data/cores
mkdir -p "$CORES"
# Arquivos que o EmulatorJS espera dentro do pacote (os mesmos do pacote oficial do fceumm).
META=$(mktemp -d)
tr -d '\r' < /src/fceumm.core.json > "$META/core.json"
printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$META/build.json"
cp fceumm/Copying "$META/license.txt"
START=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
for variant in "" "--legacy"; do
  name=fceumm${variant:+-legacy}-wasm.data
  rm -f "${CORES:?}/${name:?}"
  (cd RetroArch/emulatorjs && EJS_CHEEVOS=1 emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -40 /tmp/ra.log; exit 1; }
  [ -f "$CORES/$name" ] || { tail -40 /tmp/ra.log; exit 1; }
  (cd "$META" && 7z a -bd -t7z "$CORES/$name" core.json build.json license.txt >/dev/null)
  cp "$CORES/$name" "/out/$name"
done

printf '{ "core": "fceumm", "buildStart": "%s", "buildEnd": "%s", "options": {} }\n' "$START" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > /out/fceumm.json
git -C fceumm log -1 --format='fceumm %H' > /out/versions.txt
git -C RetroArch log -1 --format='retroarch %H (+ ejs_cheevos)' >> /out/versions.txt
emcc --version | head -1 >> /out/versions.txt
ls -la /out
