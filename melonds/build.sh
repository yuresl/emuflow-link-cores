#!/bin/bash
# Compila o melonDS com o Wi-Fi local entre dois consoles (D108):
#  - melonds-wasm.data e melonds-legacy-wasm.data, o console do host, no EmulatorJS;
#  - second/melonds-second.{js,wasm}, o segundo console, num worker, sem RetroArch.
# Roda na imagem emuflow-ppsspp-build (Emscripten 3.1.74): /src = esta pasta, /out = saida, /work = volume de cache.
set -euo pipefail
tr -d '\r' < /src/versions.env > /tmp/v.env; . /tmp/v.env
mkdir -p /work/link /out/second; cd /work/link

[ -d melonds/.git ] || git clone -q "$MELONDS_REPO" melonds
git -C melonds fetch -q origin
git -C melonds checkout -q -f "$MELONDS_COMMIT"
git -C melonds clean -qfdx
tr -d '\r' < /src/wifi.patch > /tmp/wifi.patch
git -C melonds apply /tmp/wifi.patch
# LTO: cerca de 4% a menos de tempo por quadro na corrida do Mario Kart DS, com a mesma imagem no fim.
CFLAGS=-flto CXXFLAGS=-flto emmake make -C melonds -j"$(nproc)" platform=emscripten >/tmp/core.log 2>&1 || { tail -30 /tmp/core.log; exit 1; }

cp melonds/melonds_libretro_emscripten.bc /tmp/melonds.a
# Sem o RetroArch, o que ele fornecia ao core vem daqui.
LC=melonds/src/libretro/libretro-common
emcc -O3 -flto -I"$LC/include" -Wl,--whole-archive /tmp/melonds.a -Wl,--no-whole-archive \
  "$LC/compat/compat_strl.c" "$LC/compat/fopen_utf8.c" "$LC/compat/compat_posix_string.c" "$LC/compat/compat_strcasestr.c" \
  "$LC/encodings/encoding_utf.c" "$LC/file/file_path.c" "$LC/streams/file_stream.c" "$LC/streams/file_stream_transforms.c" \
  "$LC/streams/memory_stream.c" "$LC/string/stdstring.c" "$LC/vfs/vfs_implementation.c" \
  -o /out/second/melonds-second.mjs \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker -sEXPORT_NAME=createMelonDs \
  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=134217728 -sALLOW_TABLE_GROWTH=1 -sFORCE_FILESYSTEM=1 -sEXIT_RUNTIME=0 \
  -sEXPORTED_FUNCTIONS=_malloc,_free,_retro_init,_retro_load_game,_retro_run,_retro_get_system_av_info,_retro_set_environment,_retro_set_video_refresh,_retro_set_audio_sample,_retro_set_audio_sample_batch,_retro_set_input_poll,_retro_set_input_state,_retro_get_memory_data,_retro_get_memory_size,_retro_reset \
  -sEXPORTED_RUNTIME_METHODS=FS,addFunction,UTF8ToString,stringToUTF8,lengthBytesUTF8,HEAPU8,HEAP16,HEAP32,HEAPU32 \
  >/tmp/second.log 2>&1 || { tail -30 /tmp/second.log; exit 1; }

[ -d RetroArch/.git ] || git clone -q --filter=blob:none "$RETROARCH_REPO" RetroArch
git -C RetroArch fetch -q origin
git -C RetroArch checkout -q -f "$RETROARCH_COMMIT"
find RetroArch/emulatorjs -maxdepth 1 -name "*.bc" -delete
cp melonds/melonds_libretro_emscripten.bc RetroArch/emulatorjs/
CORES=/work/link/EmulatorJS/data/cores
mkdir -p "$CORES"
META=$(mktemp -d)
cp /src/core.json "$META/core.json"
printf '{\n    "minimumEJSVersion": "4.3.0",\n    "version": "2.0.3"\n}' > "$META/build.json"
cp melonds/LICENSE "$META/license.txt" 2>/dev/null || cp melonds/README.md "$META/license.txt"
START=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)

for variant in "" "--legacy"; do
  name=melonds${variant:+-legacy}-wasm.data
  rm -f "${CORES:?}/${name:?}"
  (cd RetroArch/emulatorjs && emmake bash ./build-emulatorjs.sh --clean $variant >/tmp/ra.log 2>&1) || { tail -30 /tmp/ra.log; exit 1; }
  [ -f "$CORES/$name" ] || { tail -30 /tmp/ra.log; exit 1; }
  (cd "$META" && 7z a -bd -t7z "$CORES/$name" core.json build.json license.txt >/dev/null)
  cp "$CORES/$name" "/out/$name"
done

printf '{ "core": "melonds", "buildStart": "%s", "buildEnd": "%s", "options": { "defaultWebGL2": true, "supportsMouse": true } }\n' "$START" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > /out/melonds.json
git -C melonds log -1 --format='melonds %H' > /out/versions.txt
git -C RetroArch log -1 --format='retroarch %H' >> /out/versions.txt
ls -la /out /out/second
