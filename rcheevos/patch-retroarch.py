"""Liga a ponte ejs_cheevos.c no RetroArch do EmulatorJS (rode na raiz do RetroArch)."""
import re
import sys

RCHEEVOS_OBJ = """$(LIBRETRO_COMM_DIR)/formats/cdfs/cdfs.o deps/rcheevos/src/rc_client.o deps/rcheevos/src/rc_compat.o deps/rcheevos/src/rc_libretro.o \\
  deps/rcheevos/src/rc_util.o deps/rcheevos/src/rcheevos/alloc.o deps/rcheevos/src/rcheevos/condition.o \\
  deps/rcheevos/src/rcheevos/condset.o deps/rcheevos/src/rcheevos/consoleinfo.o deps/rcheevos/src/rcheevos/format.o \\
  deps/rcheevos/src/rcheevos/lboard.o deps/rcheevos/src/rcheevos/memref.o deps/rcheevos/src/rcheevos/operand.o \\
  deps/rcheevos/src/rcheevos/richpresence.o deps/rcheevos/src/rcheevos/runtime.o \\
  deps/rcheevos/src/rcheevos/runtime_progress.o deps/rcheevos/src/rcheevos/trigger.o deps/rcheevos/src/rcheevos/value.o \\
  deps/rcheevos/src/rhash/aes.o deps/rcheevos/src/rhash/cdreader.o deps/rcheevos/src/rhash/hash.o \\
  deps/rcheevos/src/rhash/hash_disc.o deps/rcheevos/src/rhash/hash_encrypted.o deps/rcheevos/src/rhash/hash_rom.o \\
  deps/rcheevos/src/rhash/hash_zip.o deps/rcheevos/src/rapi/rc_api_common.o deps/rcheevos/src/rapi/rc_api_info.o \\
  deps/rcheevos/src/rapi/rc_api_runtime.o deps/rcheevos/src/rapi/rc_api_user.o"""

EXPORTS = ",_ejs_cheevos_init,_ejs_cheevos_login_token,_ejs_cheevos_load_game,_ejs_cheevos_set_hardcore," \
          "_ejs_cheevos_reset,_ejs_cheevos_reset_progress,_ejs_cheevos_change_media,_ejs_cheevos_unload," \
          "_ejs_cheevos_http_response"


def patch(path, old, new, marker):
    text = open(path, encoding='utf-8').read()
    if marker in text:
        return
    if old not in text:
        sys.exit(f'{path}: trecho não encontrado: {old[:60]!r}')
    open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))


# Makefile.emulatorjs: objetos do rcheevos + a ponte, e as funções exportadas.
patch('Makefile.emulatorjs', 'include Makefile.common\n', f"""include Makefile.common

# EmuFlow: conquistas ao vivo (ejs_cheevos.c), sem o cheevos.c do RetroArch (usa a rede dele).
ifeq ($(EJS_CHEEVOS), 1)
   DEFINES += -DEMULATORJS_CHEEVOS -DRC_CLIENT_SUPPORTS_HASH -DRC_NO_THREADS -Ideps/rcheevos/include
   OBJ += emulatorjs/ejs_cheevos.o {RCHEEVOS_OBJ}
   # O rhash/aes.c do rcheevos é o tiny-AES, que o melonDS também traz (DSi): renomeia o do RetroArch.
   DEFINES += -DAES_init_ctx=rc_AES_init_ctx -DAES_init_ctx_iv=rc_AES_init_ctx_iv -DAES_ctx_set_iv=rc_AES_ctx_set_iv \\
              -DAES_ECB_encrypt=rc_AES_ECB_encrypt -DAES_ECB_decrypt=rc_AES_ECB_decrypt \\
              -DAES_CBC_encrypt_buffer=rc_AES_CBC_encrypt_buffer -DAES_CBC_decrypt_buffer=rc_AES_CBC_decrypt_buffer \\
              -DAES_CTR_xcrypt_buffer=rc_AES_CTR_xcrypt_buffer
   # Cores com o próprio libchdr (noCHD): o Makefile.common renomeia quase tudo do libchdr do RetroArch; faltam estes.
   ifeq ($(HAVE_STATIC_CORES), 1)
      DEFINES += -Dcrc16=retroarch_internal_crc16 -Dchd_open_core_file=retroarch_internal_chd_open_core_file \\
                 -Dchd_read_header=retroarch_internal_chd_read_header
   endif
   EXPORTED_FUNCTIONS := $(EXPORTED_FUNCTIONS){EXPORTS}
   LDFLAGS := $(subst EXPORTED_FUNCTIONS="$(EXPORTED_FUNCTIONS_BASE)",EXPORTED_FUNCTIONS="$(EXPORTED_FUNCTIONS)",$(LDFLAGS))
endif
""", 'EMULATORJS_CHEEVOS')

# O LDFLAGS já foi montado antes com a lista base: guarda a base para trocar acima.
text = open('Makefile.emulatorjs', encoding='utf-8').read()
if 'EXPORTED_FUNCTIONS_BASE' not in text.split('include Makefile.common')[0]:
    text = text.replace('-s EXPORTED_FUNCTIONS="$(EXPORTED_FUNCTIONS)"', '-s EXPORTED_FUNCTIONS="$(EXPORTED_FUNCTIONS_BASE)"', 1)
    text = text.replace('\nEXPORTS :=', '\nEXPORTED_FUNCTIONS_BASE := $(EXPORTED_FUNCTIONS)\nEXPORTS :=', 1)
    open('Makefile.emulatorjs', 'w', encoding='utf-8').write(text)

# build-emulatorjs.sh: com EJS_CHEEVOS=1, todo core sai com o leitor de .chd do RetroArch (o hash dos jogos de
# disco precisa dele), inclusive os da lista noCHD (genesis_plus_gx, pcsx_rearmed), que trazem o próprio libchdr.
# HAVE_STATIC_CORES=1 só renomeia os símbolos do libchdr do RetroArch (retroarch_internal_*) para não baterem
# com os do core.
# Só nesses: nos outros, o core usa o libchdr do RetroArch (como no build oficial) e renomear puxaria o do core.
patch('emulatorjs/build-emulatorjs.sh',
      '''  if [[ $(containsElement $name "${noCHD[@]}") = 1 ]]; then
    chd=0
  fi''',
      '''  staticchd=0
  if [[ $(containsElement $name "${noCHD[@]}") = 1 ]]; then
    chd=0
    if [[ -n "$EJS_CHEEVOS" ]]; then chd=1; staticchd=1; fi
  fi''',
      'staticchd=0')
text = open('emulatorjs/build-emulatorjs.sh', encoding='utf-8').read()
if 'HAVE_STATIC_CORES=' not in text:
    if 'HAVE_CHD=$chd ' not in text:
        sys.exit('build-emulatorjs.sh: HAVE_CHD=$chd não encontrado')
    # FLAC embutido: os .chd de CD (chdman) guardam o áudio em FLAC, e sem esse codec o chd_open recusa o arquivo.
    text = text.replace('HAVE_CHD=$chd ', 'HAVE_CHD=$chd HAVE_STATIC_CORES=$staticchd HAVE_BUILTINFLAC=${EJS_CHEEVOS:+1} ')
    open('emulatorjs/build-emulatorjs.sh', 'w', encoding='utf-8').write(text)

# runloop.c: rc_client_do_frame depois de cada quadro; idle no menu/pausa.
patch('runloop.c', """#ifdef HAVE_CHEEVOS
   if (cheevos_enable)
      rcheevos_test();
#endif
#ifdef HAVE_CHEATS
   cheat_manager_apply_retro_cheats();""", """#ifdef HAVE_CHEEVOS
   if (cheevos_enable)
      rcheevos_test();
#endif
#ifdef EMULATORJS_CHEEVOS
   ejs_cheevos_do_frame();
#endif
#ifdef HAVE_CHEATS
   cheat_manager_apply_retro_cheats();""", 'ejs_cheevos_do_frame')
patch('runloop.c', '#ifdef HAVE_CHEEVOS\n', '#ifdef EMULATORJS_CHEEVOS\nvoid ejs_cheevos_do_frame(void);\nvoid ejs_cheevos_idle(void);\n#endif\n#ifdef HAVE_CHEEVOS\n', 'void ejs_cheevos_idle(void);')
patch('runloop.c', """#ifdef HAVE_CHEEVOS
         if (cheevos_enable)
         {
            if (runloop_is_libretro_running(runloop_st, menu_pause_libretro))
               rcheevos_test();
            else
               rcheevos_idle();
         }
#endif""", """#ifdef HAVE_CHEEVOS
         if (cheevos_enable)
         {
            if (runloop_is_libretro_running(runloop_st, menu_pause_libretro))
               rcheevos_test();
            else
               rcheevos_idle();
         }
#endif
#ifdef EMULATORJS_CHEEVOS
         ejs_cheevos_idle();
#endif""", 'ejs_cheevos_idle();\n#endif')
print('RetroArch ajustado para o ejs_cheevos.')
