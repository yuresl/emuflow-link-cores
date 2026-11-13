#!/bin/bash
# Compila os portateis com o cabo ligado ao site (Module.emuflowSerial): o console do host, no EmulatorJS, e o
# second/<core>-second.{mjs,wasm}, o segundo console, num worker, sem RetroArch (modo hospedado).
# bash build.sh <ngp|wswan|handy|gg>...   sem argumentos, todos.
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74): /src = esta pasta, /out = saida, /work = volume de cache,
# /cheevos = link-core/rcheevos (conquistas ao vivo).
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
mkdir -p /work/link /out/second; cd /work/link

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
# Conquistas ao vivo (D151): a ponte do link-core/rcheevos, montada em /cheevos.
[ -f /cheevos/retroarch-cheevos.sh ] || { echo "monte link-core/rcheevos em /cheevos (-v ...:/cheevos:ro)"; exit 1; }
tr -d '\r' < /cheevos/retroarch-cheevos.sh > /tmp/retroarch-cheevos.sh
bash /tmp/retroarch-cheevos.sh RetroArch /cheevos

build() {
  local id=$1 dir=$2 repo=$3 commit=$4 name=$5 makefile=$6
  [ -d "$dir/.git" ] || git clone -q "$repo" "$dir"
  git -C "$dir" fetch -q origin || true
  git -C "$dir" checkout -q -f "$commit"
  git -C "$dir" clean -qfdx
  tr -d '\r' < "/src/$id.patch" > /tmp/core.patch
  git -C "$dir" apply --ignore-whitespace /tmp/core.patch
  emmake make -C "$dir" -f "$makefile" -j"$(nproc)" platform=emscripten >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }
  local bc="$dir/${name}_libretro_emscripten.bc"

  # Sem o RetroArch, o que ele fornecia ao core vem daqui. Numa biblioteca, para so entrar o que faltar.
  local lc extra=/tmp/extra-$id
  lc=$(dirname "$(dirname "$(find "$dir" -name compat_strl.c | head -1)")")
  rm -rf "$extra"; mkdir -p "$extra"
  local i=0
  for file in compat/compat_strl.c compat/fopen_utf8.c compat/compat_posix_string.c compat/compat_strcasestr.c \
      encodings/encoding_utf.c file/file_path.c file/file_path_io.c streams/file_stream.c streams/file_stream_transforms.c \
      streams/memory_stream.c string/stdstring.c vfs/vfs_implementation.c time/rtime.c; do
    [ -f "$lc/$file" ] || continue
    i=$((i + 1))
    emcc -O3 -I"$lc/include" -c "$lc/$file" -o "$extra/$i.o"
  done
  emar rcs "$extra/libextra.a" "$extra"/*.o
  cp "$bc" "/tmp/$name.a"
  em++ -O3 -Wl,--whole-archive "/tmp/$name.a" -Wl,--no-whole-archive "$extra/libextra.a" \
    -o "/out/second/$name-second.mjs" \
    -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker -sEXPORT_NAME=createCore \
    -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=67108864 -sALLOW_TABLE_GROWTH=1 -sFORCE_FILESYSTEM=1 -sEXIT_RUNTIME=0 \
    -sEXPORTED_FUNCTIONS=_malloc,_free,_retro_init,_retro_load_game,_retro_run,_retro_get_system_av_info,_retro_set_environment,_retro_set_video_refresh,_retro_set_audio_sample,_retro_set_audio_sample_batch,_retro_set_input_poll,_retro_set_input_state,_retro_get_memory_data,_retro_get_memory_size,_retro_reset \
    -sEXPORTED_RUNTIME_METHODS=FS,addFunction,UTF8ToString,stringToUTF8,lengthBytesUTF8,HEAPU8,HEAP16,HEAP32,HEAPU32 \
    >/tmp/second.log 2>&1 || { tail -30 /tmp/second.log; exit 1; }

  find RetroArch/emulatorjs -maxdepth 1 -name "*.bc" -delete
  cp "$bc" RetroArch/emulatorjs/
  local cores=/work/link/EmulatorJS/data/cores meta
  mkdir -p "$cores"
  meta=$(mktemp -d)
  cp "/src/$id.core.json" "$meta/core.json"
  printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$meta/build.json"
  cp "$dir"/LICENSE* "$meta/license.txt" 2>/dev/null || cp "$dir"/COPYING* "$meta/license.txt" 2>/dev/null || cp "$dir"/README* "$meta/license.txt"
  local start variant file
  start=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
  for variant in "" "--legacy"; do
    file=$name${variant:+-legacy}-wasm.data
    rm -f "${cores:?}/${file:?}"
    (cd RetroArch/emulatorjs && EJS_CHEEVOS=1 emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -30 /tmp/ra.log; exit 1; }
    [ -f "$cores/$file" ] || { tail -30 /tmp/ra.log; exit 1; }
    (cd "$meta" && 7z a -bd -t7z "$cores/$file" core.json build.json license.txt >/dev/null)
    cp "$cores/$file" "/out/$file"
  done
  printf '{ "core": "%s", "buildStart": "%s", "buildEnd": "%s", "options": %s }\n' "$name" "$start" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
    "$(python3 -c "import json;print(json.dumps(json.load(open('/src/$id.core.json')).get('options',{})))")" > "/out/$name.json"
  git -C "$dir" log -1 --format="$name %H" >> /out/versions.txt
  echo "pronto: $name"
}

for id in "${@:-ngp wswan handy gg}"; do
  for one in $id; do
    case "$one" in
      ngp) build ngp beetle-ngp-libretro "$NGP_REPO" "$NGP_COMMIT" mednafen_ngp Makefile ;;
      wswan) build wswan beetle-wswan-libretro "$WSWAN_REPO" "$WSWAN_COMMIT" mednafen_wswan Makefile ;;
      handy) build handy libretro-handy "$HANDY_REPO" "$HANDY_COMMIT" handy Makefile ;;
      gg) build gg Genesis-Plus-GX "$GPGX_REPO" "$GPGX_COMMIT" genesis_plus_gx Makefile.libretro ;;
      *) echo "core? $one"; exit 1 ;;
    esac
  done
done
ls -la /out /out/second
