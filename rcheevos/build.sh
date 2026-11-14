#!/bin/bash
# Compila cores sem cabo com o runtime de conquistas (rcheevos + ejs_cheevos.c), nas duas variantes que o player
# usa. Etapa B do RetroAchievements (plano da API, seção 7.2). Cores, commits e pastas em cores.list.
#   bash build.sh [core...]   sem argumentos, todos os de cores.list
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74; Dockerfile nesta pasta):
#   docker run --rm -v emuflow-ppsspp-work:/work -v "<pasta>:/src:ro" -v "<pasta>\out:/out" emuflow-ppsspp-build \
#     bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh snes9x picodrive"
# Saída: /out/<core>{,-legacy}-wasm.data e /out/<core>.json (para cores/reports), e /out/versions.txt.
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
tr -d '\r' < /src/cores.list | grep -v '^#' | grep -v '^[[:space:]]*$' > /tmp/cores.list
tr -d '\r' < /src/retroarch-cheevos.sh > /tmp/retroarch-cheevos.sh
mkdir -p /work/cheevos /out; cd /work/cheevos
# O cache do Emscripten é do container: sem isso, um core que inclui <zlib.h> (pcsx_rearmed) só compila depois de
# outro ter instalado a porta do zlib.
embuilder build zlib >/dev/null

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
git -C RetroArch clean -qfdx emulatorjs
bash /tmp/retroarch-cheevos.sh RetroArch /src
git -C RetroArch log -1 --format='retroarch %H (+ ejs_cheevos)' > /out/versions.txt
emcc --version | head -1 >> /out/versions.txt

CORES=/work/cheevos/EmulatorJS/data/cores
mkdir -p "$CORES"

build() {
  local name=$1 repo dir commit path makefile
  read -r _ repo commit path makefile < <(awk -v n="$name" '$1 == n' /tmp/cores.list)
  [ -n "${repo:-}" ] || { echo "core fora do cores.list: $name"; exit 1; }
  dir=src-$name
  [ -d "$dir/.git" ] || git clone -q "$repo" "$dir"
  git -C "$dir" fetch -q origin || true
  git -C "$dir" checkout -q -f "$commit"
  git -C "$dir" clean -qfdx
  git -C "$dir" submodule -q update --init --recursive 2>/dev/null || true
  emmake make -C "$dir/$path" -f "$makefile" -j"$(nproc)" platform=emscripten >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }

  find RetroArch/emulatorjs -maxdepth 1 -name '*.bc' -delete
  local bc
  bc=$(find "$dir/$path" -maxdepth 1 -name '*_libretro_emscripten.bc' | head -1)
  [ -n "$bc" ] || { echo "sem *_libretro_emscripten.bc em $dir/$path"; ls "$dir/$path"; exit 1; }
  # O nome do .bc vira o nome do core no pacote (o beetle_vb sai como mednafen_vb_libretro_emscripten.bc).
  cp "$bc" "RetroArch/emulatorjs/${name}_libretro_emscripten.bc"

  # Arquivos que o EmulatorJS espera dentro do pacote (os mesmos do pacote oficial).
  local meta license
  meta=$(mktemp -d)
  tr -d '\r' < "/src/$name.core.json" > "$meta/core.json"
  printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$meta/build.json"
  license=$(python3 -c "import json;print(json.load(open('$meta/core.json')).get('license') or '')")
  if [ -n "$license" ] && [ -f "$dir/$license" ]; then cp "$dir/$license" "$meta/license.txt"
  else cp "$dir"/LICENSE* "$meta/license.txt" 2>/dev/null || cp "$dir"/COPYING* "$meta/license.txt" 2>/dev/null || cp "$dir"/README* "$meta/license.txt"
  fi

  local start variant file
  start=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
  for variant in "" "--legacy"; do
    file=$name${variant:+-legacy}-wasm.data
    rm -f "${CORES:?}/${file:?}"
    (cd RetroArch/emulatorjs && EJS_CHEEVOS=1 emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -40 /tmp/ra.log; exit 1; }
    [ -f "$CORES/$file" ] || { tail -40 /tmp/ra.log; exit 1; }
    (cd "$meta" && 7z a -bd -t7z "$CORES/$file" core.json build.json license.txt >/dev/null)
    cp "$CORES/$file" "/out/$file"
  done
  printf '{ "core": "%s", "buildStart": "%s", "buildEnd": "%s", "options": %s }\n' "$name" "$start" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
    "$(python3 -c "import json;print(json.dumps(json.load(open('$meta/core.json')).get('options',{})))")" > "/out/$name.json"
  git -C "$dir" log -1 --format="$name %H" >> /out/versions.txt
  echo "pronto: $name"
}

if [ $# -eq 0 ]; then set -- $(awk '{print $1}' /tmp/cores.list); fi
for name in "$@"; do build "$name"; done
ls -la /out
