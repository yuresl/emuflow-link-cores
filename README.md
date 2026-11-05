# Cores com cabo link do EmuFlow

Receitas dos cores que o [EmuFlow](https://emuflow.com.br) usa no multiplayer dos portáteis. Cada pasta tem o patch, os commits fixados em `versions.env` e o `build.sh`. O código é publicado para cumprir as licenças dos emuladores. Cada patch segue a licença do core em que é aplicado.

| Pasta | Console | Core | Licença do core |
|---|---|---|---|
| `gambatte/` | Game Boy e Game Boy Color | [gambatte-libretro (EmulatorJS)](https://github.com/EmulatorJS/gambatte-libretro) | GPL-2.0 |
| `mgba/` | Game Boy Advance | [mgba-wifi-link](https://github.com/Aelvryx/mgba-wifi-link) | MPL-2.0 |
| `melonds/` | Nintendo DS | [melonDS (EmulatorJS)](https://github.com/EmulatorJS/melonDS), com o Wi-Fi do melonDS 0.9.5 | GPL-3.0 |
| `handhelds/` | Neo Geo Pocket | [beetle-ngp-libretro](https://github.com/libretro/beetle-ngp-libretro) | GPL-2.0 |
| `handhelds/` | WonderSwan | [beetle-wswan-libretro](https://github.com/libretro/beetle-wswan-libretro) | GPL-2.0 |
| `handhelds/` | Lynx | [libretro-handy](https://github.com/libretro/libretro-handy) | Ver o repositório do core |
| `handhelds/` | Game Gear | [Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | Ver `LICENSE.txt` do core |

Todos são ligados ao [RetroArch do EmulatorJS](https://github.com/EmulatorJS/RetroArch), no commit indicado em cada `versions.env`.

## Como compilar

Na imagem `emuflow-ppsspp-build` (Emscripten 3.1.74), descrita em [emuflow-ppsspp-core](https://github.com/yuresl/emuflow-ppsspp-core), com o volume `emuflow-ppsspp-work`. `/src` é a pasta do core, e `/out` recebe o resultado:

```bash
docker run --rm -v emuflow-ppsspp-work:/work -v "$PWD/melonds:/src:ro" -v "$PWD/melonds/out:/out" emuflow-ppsspp-build \
  bash -c "tr -d '\r' < /src/build.sh > /tmp/b.sh; bash /tmp/b.sh"
```

Em `handhelds/`, `build.sh` recebe o console (`ngp`, `wswan`, `handy` ou `gg`), e os patches são gerados pelo `apply-hh.py`.
