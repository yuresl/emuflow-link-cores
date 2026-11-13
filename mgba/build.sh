#!/bin/bash
# Compila o mGBA com o par replicado (D106) nas duas variantes que o player usa.
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74): /src = esta pasta, /out = saida, /work = volume de cache,
# /cheevos = link-core/rcheevos (conquistas ao vivo).
# EMUFLOW_LINK_TEST=1 expoe a memoria do jogo ao roteiro de teste: nunca instalar esse build no site.
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
TEST_FLAG=""; [ "${EMUFLOW_LINK_TEST:-0}" = "1" ] && TEST_FLAG="-DEMUFLOW_LINK_TEST"
mkdir -p /work/link /out; cd /work/link

[ -d mgba-prod/.git ] || git clone -q "$MGBA_REPO" mgba-prod
git -C mgba-prod fetch -q origin
git -C mgba-prod checkout -q -f "$MGBA_COMMIT"
git -C mgba-prod clean -qfdx
tr -d '\r' < /src/par.patch > /tmp/par.patch
git -C mgba-prod apply /tmp/par.patch
cd mgba-prod
emcmake cmake -S . -B b -DCMAKE_BUILD_TYPE=Release "-DCMAKE_C_FLAGS=-std=gnu11 ${TEST_FLAG} -D_GNU_SOURCE -D_DEFAULT_SOURCE -Wno-int-conversion" -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_LIBRETRO=ON -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
  -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_EPOXY=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_DISCORD_RPC=OFF -DENABLE_SCRIPTING=OFF -DUSE_PNG=OFF -DUSE_ZLIB=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DENABLE_DEBUGGERS=OFF 2>&1 | tail -6
# O CMake poe -pthread: sem threads, o quadro cai de 14 para 8,4 ms.
sed -i 's/-pthread//g' b/CMakeFiles/mgba_libretro.dir/flags.make
emmake make -C b -j"$(nproc)" mgba_libretro >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }
cd /work/link

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
# Conquistas ao vivo (D151): a ponte do link-core/rcheevos, montada em /cheevos.
[ -f /cheevos/retroarch-cheevos.sh ] || { echo "monte link-core/rcheevos em /cheevos (-v ...:/cheevos:ro)"; exit 1; }
tr -d '\r' < /cheevos/retroarch-cheevos.sh > /tmp/retroarch-cheevos.sh
bash /tmp/retroarch-cheevos.sh RetroArch /cheevos
find RetroArch/emulatorjs -maxdepth 1 -name '*.bc' -delete
cp mgba-prod/b/mgba_libretro.a RetroArch/emulatorjs/mgba_libretro_emscripten.bc
CORES=/work/link/EmulatorJS/data/cores
mkdir -p "$CORES"
META=$(mktemp -d)
cp /src/core.json "$META/core.json"
printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$META/build.json"
cp mgba-prod/LICENSE "$META/license.txt"
START=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)

for variant in "" "--legacy"; do
  name=mgba${variant:+-legacy}-wasm.data
  rm -f "${CORES:?}/${name:?}"
  (cd RetroArch/emulatorjs && EJS_CHEEVOS=1 emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -30 /tmp/ra.log; exit 1; }
  [ -f "$CORES/$name" ] || { tail -30 /tmp/ra.log; exit 1; }
  (cd "$META" && 7z a -bd -t7z "$CORES/$name" core.json build.json license.txt >/dev/null)
  cp "$CORES/$name" "/out/$name"
done

printf '{ "core": "mgba", "buildStart": "%s", "buildEnd": "%s", "options": {} }\n' "$START" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > /out/mgba.json
git -C mgba-prod log -1 --format='mgba-wifi-link %H' > /out/versions.txt
git -C RetroArch log -1 --format='retroarch %H' >> /out/versions.txt
emcc --version | head -1 >> /out/versions.txt
ls -la /out
