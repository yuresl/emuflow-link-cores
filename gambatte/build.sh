#!/bin/bash
# Compila o gambatte com o cabo (D106) nas duas variantes que o player usa.
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74): /src = esta pasta, /out = saida, /work = volume de cache,
# /cheevos = link-core/rcheevos (conquistas ao vivo).
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
mkdir -p /work/link /out; cd /work/link

[ -d gambatte/.git ] || git clone -q "$GAMBATTE_REPO" gambatte
git -C gambatte fetch -q origin
git -C gambatte checkout -q -f "$GAMBATTE_COMMIT"
git -C gambatte clean -qfdx
tr -d '\r' < /src/cabo.patch > /tmp/cabo.patch
git -C gambatte apply /tmp/cabo.patch
emmake make -C gambatte -j"$(nproc)" -f Makefile.libretro platform=emscripten >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
# Conquistas ao vivo (D151): a ponte do link-core/rcheevos, montada em /cheevos.
[ -f /cheevos/retroarch-cheevos.sh ] || { echo "monte link-core/rcheevos em /cheevos (-v ...:/cheevos:ro)"; exit 1; }
tr -d '\r' < /cheevos/retroarch-cheevos.sh > /tmp/retroarch-cheevos.sh
bash /tmp/retroarch-cheevos.sh RetroArch /cheevos
find RetroArch/emulatorjs -maxdepth 1 -name "*.bc" -delete
cp gambatte/*.bc RetroArch/emulatorjs/
CORES=/work/link/EmulatorJS/data/cores
mkdir -p "$CORES"
META=$(mktemp -d)
cp /src/core.json "$META/core.json"
printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$META/build.json"
cp gambatte/COPYING "$META/license.txt"
START=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)

for variant in "" "--legacy"; do
  name=gambatte${variant:+-legacy}-wasm.data
  rm -f "${CORES:?}/${name:?}"
  (cd RetroArch/emulatorjs && EJS_CHEEVOS=1 emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -30 /tmp/ra.log; exit 1; }
  [ -f "$CORES/$name" ] || { tail -30 /tmp/ra.log; exit 1; }
  (cd "$META" && 7z a -bd -t7z "$CORES/$name" core.json build.json license.txt >/dev/null)
  cp "$CORES/$name" "/out/$name"
done

printf '{ "core": "gambatte", "buildStart": "%s", "buildEnd": "%s", "options": {} }\n' "$START" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > /out/gambatte.json
git -C gambatte log -1 --format='gambatte %H' > /out/versions.txt
git -C RetroArch log -1 --format='retroarch %H' >> /out/versions.txt
emcc --version | head -1 >> /out/versions.txt
ls -la /out
