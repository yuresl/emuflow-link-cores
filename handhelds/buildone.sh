#!/bin/bash
# Refaz o <core>.patch a partir do apply-hh.py, compila o core e instala em public/emulatorjs.
#   bash buildone.sh <ngp|wswan|handy|gg>           patch, build e instalacao
#   bash buildone.sh <ngp|wswan|handy|gg> --patch   so refaz o patch
# Com HHDBG=1, o patch ganha ganchos de depuracao: nunca commitar um patch feito assim.
# Precisa do repositorio do core ja em /work/link: rode o build.sh uma vez antes (ver o cabecalho dele).
set -euo pipefail
id=${1:?core}
mode=${2:-}
case "$id" in
  ngp) dir=beetle-ngp-libretro; name=mednafen_ngp ;;
  wswan) dir=beetle-wswan-libretro; name=mednafen_wswan ;;
  handy) dir=libretro-handy; name=handy ;;
  gg) dir=Genesis-Plus-GX; name=genesis_plus_gx ;;
  *) echo "core? $id"; exit 1 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
# Caminho que o Docker do Windows entende; em Linux e macOS, `pwd -W` nao existe e vale o normal.
W=$(cd "$here" && pwd -W 2>/dev/null || pwd)
export MSYS_NO_PATHCONV=1

docker run --rm -v emuflow-ppsspp-work:/work -v "$W:/s" emuflow-ppsspp-build bash -c "
  set -e
  cd /work/link/$dir
  git checkout -q -f HEAD
  git clean -qfdx
  HHDBG=${HHDBG:-} python3 /s/apply-hh.py $id \$PWD
  git diff > /s/$id.patch
  wc -l /s/$id.patch"

[ "$mode" = "--patch" ] && exit 0

docker run --rm --name link-hh -v emuflow-ppsspp-work:/work -v "$W:/src:ro" -v "$W/../rcheevos:/cheevos:ro" -v "$W/out:/out" emuflow-ppsspp-build \
  bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh $id" 2>&1 \
  | grep -v '^-rw\|^drw\|^total\|^$\|^/out\|^-rwx' | tail -6

root=$here/../..
out=$here/out
cp "$out/$name-wasm.data" "$out/$name-legacy-wasm.data" "$root/public/emulatorjs/cores/"
cp "$out/$name.json" "$root/public/emulatorjs/cores/reports/$name.json"
cp "$out/second/$name-second."* "$root/public/emulatorjs/second/"
cut -c1-70 "$root/public/emulatorjs/cores/reports/$name.json"
