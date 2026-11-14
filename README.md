# Cores com cabo link do EmuFlow

Receitas dos cores que o [EmuFlow](https://emuflow.com.br) usa no multiplayer dos portáteis e nas conquistas ao vivo do RetroAchievements. Cada pasta tem o patch, os commits fixados em `versions.env` e o `build.sh`. O código é publicado para cumprir as licenças dos emuladores. Cada patch segue a licença do core em que é aplicado.

| Pasta | Console | Core | Licença do core |
|---|---|---|---|
| `gambatte/` | Game Boy e Game Boy Color | [gambatte-libretro (EmulatorJS)](https://github.com/EmulatorJS/gambatte-libretro) | GPL-2.0 |
| `mgba/` | Game Boy Advance | [mgba-wifi-link](https://github.com/Aelvryx/mgba-wifi-link) | MPL-2.0 |
| `melonds/` | Nintendo DS | [melonDS (EmulatorJS)](https://github.com/EmulatorJS/melonDS), com o Wi-Fi do melonDS 0.9.5 | GPL-3.0 |
| `handhelds/` | Neo Geo Pocket | [beetle-ngp-libretro](https://github.com/libretro/beetle-ngp-libretro) | GPL-2.0 |
| `handhelds/` | WonderSwan | [beetle-wswan-libretro](https://github.com/libretro/beetle-wswan-libretro) | GPL-2.0 |
| `handhelds/` | Lynx | [libretro-handy](https://github.com/libretro/libretro-handy) | Ver o repositório do core |
| `handhelds/` | Game Gear | [Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | Ver `LICENSE.txt` do core |
| `rcheevos/` | Conquistas ao vivo nos consoles sem cabo: NES, SNES, Master System e SG-1000, 32X, PC Engine e PC Engine CD, Atari 2600 e 7800, Virtual Boy, ColecoVision, Intellivision, Jaguar, PS1, PC-FX, Saturn, 3DO e Nintendo 64 | Os forks do EmulatorJS listados em `rcheevos/cores.list` (fceumm, snes9x, smsplus, picodrive, beetle-pce, stella2014, prosystem, beetle-vb, Gearcoleco, FreeIntv, virtualjaguar, pcsx_rearmed, beetle-pcfx, yabause, opera, mupen64plus-libretro-nx) + [rcheevos](https://github.com/RetroAchievements/rcheevos) do RetroArch | A de cada core (ver o repositório dele), MIT (rcheevos) |

Todos são ligados ao [RetroArch do EmulatorJS](https://github.com/EmulatorJS/RetroArch), no commit indicado em cada `versions.env`.

## Como compilar

Na imagem `emuflow-ppsspp-build` (Emscripten 3.1.74), descrita em [emuflow-ppsspp-core](https://github.com/yuresl/emuflow-ppsspp-core), com o volume `emuflow-ppsspp-work`. `/src` é a pasta do core, e `/out` recebe o resultado:

```bash
docker run --rm -v emuflow-ppsspp-work:/work -v "$PWD/melonds:/src:ro" -v "$PWD/melonds/out:/out" emuflow-ppsspp-build \
  bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh"
```

Em `handhelds/`, `build.sh` recebe o console (`ngp`, `wswan`, `handy` ou `gg`), e os patches são gerados pelo `apply-hh.py`.

Os builds com cabo (`gambatte/`, `mgba/`, `melonds/`, `handhelds/`) também levam as conquistas ao vivo e precisam da pasta `rcheevos/` montada em `/cheevos`: acrescente `-v "$PWD/rcheevos:/cheevos:ro"` ao comando acima.

## Conquistas ao vivo (`rcheevos/`)

`ejs_cheevos.c` liga o `rc_client` do [rcheevos](https://github.com/RetroAchievements/rcheevos) (o que já vem em `deps/rcheevos` no RetroArch do EmulatorJS) ao site: funções exportadas `ejs_cheevos_*`, pedidos HTTP repassados à página por `Module.ejsCheevosHttp` e eventos em JSON por `Module.ejsCheevosEvent`. A memória do jogo é lida pelo mapa de memória do core (`rc_libretro`), e `rc_client_do_frame` roda depois de cada quadro. O `patch-retroarch.py` acrescenta isso ao `Makefile.emulatorjs` e ao `runloop.c` quando `EJS_CHEEVOS=1`. O `Dockerfile` desta pasta monta a imagem `emuflow-ppsspp-build`.

`build.sh` recebe os cores a compilar (sem argumentos, todos os de `cores.list`), cada um com o repositório, o commit, a pasta e o makefile em `cores.list` e o `<core>.core.json` que vai dentro do pacote. `retroarch-cheevos.sh` aplica a ponte num RetroArch já no commit certo; os builds com cabo usam o mesmo script.

```bash
docker run --rm -v emuflow-ppsspp-work:/work -v "$PWD/rcheevos:/src:ro" -v "$PWD/rcheevos/out:/out" emuflow-ppsspp-build \
  bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh snes9x picodrive"
```

Jogos de disco: o hash do `.chd` usa o leitor do próprio RetroArch (`cdfs` + `libchdr` do libretro-common). O `patch-retroarch.py` liga o FLAC embutido (`HAVE_BUILTINFLAC=1`), porque os `.chd` de CD do chdman guardam o áudio em FLAC, e, nos cores que trazem o próprio libchdr (`noCHD` do `build-emulatorjs.sh`: pcsx_rearmed, genesis_plus_gx), compila o do RetroArch com os símbolos renomeados (`HAVE_STATIC_CORES=1`). O Sega CD sai do `genesis_plus_gx` de `handhelds/`.

O `rhash/aes.c` do rcheevos é o tiny-AES, que o melonDS também traz: o `patch-retroarch.py` renomeia as funções `AES_*` do RetroArch para `rc_AES_*`.
