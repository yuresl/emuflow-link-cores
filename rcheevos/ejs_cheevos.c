/*
 * EmuFlow: ponte entre o rc_client (rcheevos) e o site, para o RetroArch do
 * EmulatorJS (copiado para RetroArch/emulatorjs/ pelo build.sh). Etapa B do
 * RetroAchievements: docs/planejamento/retroachievements.md (API), seção 7.2.
 *
 * - Funções exportadas `ejs_cheevos_*`, chamadas pelo site (coreBridge.ts).
 * - Pedidos HTTP do rc_client vão para Module.ejsCheevosHttp(url, postData, id);
 *   o site repassa ao proxy da API e devolve por ejs_cheevos_http_response.
 * - Eventos vão em JSON para Module.ejsCheevosEvent(json).
 * - Memória do jogo pelo mapa de memória do core (rc_libretro), igual ao
 *   cheevos.c do RetroArch; ejs_cheevos_do_frame() roda depois de cada core_run.
 */
#ifdef EMULATORJS_CHEEVOS

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <emscripten.h>

#include <file/file_path.h>
#include <string/stdstring.h>
#include <streams/interface_stream.h>
#include <formats/cdfs.h>
#include <streams/chd_stream.h>

#include "../deps/rcheevos/include/rc_client.h"
#include "../deps/rcheevos/include/rc_hash.h"
#include "../deps/rcheevos/src/rc_libretro.h"
#include "../runloop.h"
#include "../paths.h"
#include "../core.h"

#define EJS_CHEEVOS_MAX_PENDING 64

static rc_client_t *ejs_client = NULL;
static rc_libretro_memory_regions_t ejs_memory;
static int ejs_memory_ready = 0;

typedef struct
{
   rc_client_server_callback_t callback;
   void *callback_data;
   int used;
} ejs_pending_t;

static ejs_pending_t ejs_pending[EJS_CHEEVOS_MAX_PENDING];

/* ---------- JSON ---------- */

typedef struct
{
   char *data;
   size_t size;
   size_t len;
} ejs_buf_t;

static void buf_put(ejs_buf_t *buf, const char *text)
{
   size_t add = strlen(text);
   if (buf->len + add + 1 > buf->size)
   {
      size_t size = (buf->size ? buf->size : 256);
      while (buf->len + add + 1 > size)
         size *= 2;
      buf->data = (char*)realloc(buf->data, size);
      buf->size = size;
   }
   memcpy(buf->data + buf->len, text, add + 1);
   buf->len += add;
}

static void buf_str(ejs_buf_t *buf, const char *text)
{
   char tmp[8];
   buf_put(buf, "\"");
   for (; text && *text; ++text)
   {
      unsigned char c = (unsigned char)*text;
      if (c == '"' || c == '\\')
      {
         tmp[0] = '\\'; tmp[1] = (char)c; tmp[2] = '\0';
         buf_put(buf, tmp);
      }
      else if (c < 0x20)
      {
         snprintf(tmp, sizeof(tmp), "\\u%04x", c);
         buf_put(buf, tmp);
      }
      else
      {
         tmp[0] = (char)c; tmp[1] = '\0';
         buf_put(buf, tmp);
      }
   }
   buf_put(buf, "\"");
}

static void buf_num(ejs_buf_t *buf, long long value)
{
   char tmp[32];
   snprintf(tmp, sizeof(tmp), "%lld", value);
   buf_put(buf, tmp);
}

static void ejs_emit(ejs_buf_t *buf)
{
   EM_ASM({
      if (Module.ejsCheevosEvent) Module.ejsCheevosEvent(UTF8ToString($0));
   }, buf->data);
   free(buf->data);
   buf->data = NULL;
}

static void emit_simple(const char *type)
{
   ejs_buf_t buf = {0};
   buf_put(&buf, "{\"type\":");
   buf_str(&buf, type);
   buf_put(&buf, "}");
   ejs_emit(&buf);
}

static void emit_message(const char *type, const char *message)
{
   ejs_buf_t buf = {0};
   buf_put(&buf, "{\"type\":");
   buf_str(&buf, type);
   buf_put(&buf, ",\"message\":");
   buf_str(&buf, message ? message : "");
   buf_put(&buf, "}");
   ejs_emit(&buf);
}

static void put_achievement(ejs_buf_t *buf, const rc_client_achievement_t *achievement)
{
   char url[256];
   const char *badge = achievement->badge_url;
   if (!badge || !*badge)
   {
      url[0] = '\0';
      if (rc_client_achievement_get_image_url(achievement,
            RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED, url, sizeof(url)) == RC_OK)
         badge = url;
      else
         badge = NULL;
   }
   buf_put(buf, "{\"id\":");
   buf_num(buf, achievement->id);
   buf_put(buf, ",\"title\":");
   buf_str(buf, achievement->title);
   buf_put(buf, ",\"description\":");
   buf_str(buf, achievement->description);
   buf_put(buf, ",\"points\":");
   buf_num(buf, achievement->points);
   buf_put(buf, ",\"badgeUrl\":");
   if (badge)
      buf_str(buf, badge);
   else
      buf_put(buf, "null");
   buf_put(buf, "}");
}

static void emit_achievement(const char *type, const rc_client_achievement_t *achievement, int with_progress)
{
   ejs_buf_t buf = {0};
   buf_put(&buf, "{\"type\":");
   buf_str(&buf, type);
   buf_put(&buf, ",\"achievement\":");
   put_achievement(&buf, achievement);
   if (with_progress)
   {
      buf_put(&buf, ",\"progress\":");
      buf_str(&buf, achievement->measured_progress);
   }
   buf_put(&buf, "}");
   ejs_emit(&buf);
}

static void emit_leaderboard(const char *type, const rc_client_leaderboard_t *leaderboard, int with_score)
{
   ejs_buf_t buf = {0};
   buf_put(&buf, "{\"type\":");
   buf_str(&buf, type);
   buf_put(&buf, ",\"title\":");
   buf_str(&buf, leaderboard->title);
   if (with_score)
   {
      buf_put(&buf, ",\"score\":");
      buf_str(&buf, leaderboard->tracker_value);
   }
   buf_put(&buf, "}");
   ejs_emit(&buf);
}

/* ---------- Memória e eventos ---------- */

static void ejs_get_core_memory_info(uint32_t id, rc_libretro_core_memory_info_t *info)
{
   retro_ctx_memory_info_t ctx_info;
   ctx_info.id = id;
   if (core_get_memory(&ctx_info))
   {
      info->data = (unsigned char*)ctx_info.data;
      info->size = ctx_info.size;
   }
   else
   {
      info->data = NULL;
      info->size = 0;
   }
}

static void ejs_init_memory(uint32_t console_id)
{
   unsigned i;
   struct retro_memory_map mmap;
   struct retro_memory_descriptor *descriptors = NULL;
   rarch_memory_map_t *mmaps = &runloop_state_get_ptr()->system.mmaps;

   if (ejs_memory_ready)
      rc_libretro_memory_destroy(&ejs_memory);

   if (mmaps->num_descriptors)
   {
      descriptors = (struct retro_memory_descriptor*)malloc(mmaps->num_descriptors * sizeof(*descriptors));
      for (i = 0; i < mmaps->num_descriptors; ++i)
         memcpy(&descriptors[i], &mmaps->descriptors[i].core, sizeof(descriptors[0]));
   }
   mmap.descriptors = descriptors;
   mmap.num_descriptors = mmaps->num_descriptors;
   ejs_memory_ready = rc_libretro_memory_init(&ejs_memory, &mmap, ejs_get_core_memory_info, console_id);
   free(descriptors);
}

static uint32_t ejs_read_memory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client)
{
   (void)client;
   if (!ejs_memory_ready)
      return 0;
   return rc_libretro_memory_read(&ejs_memory, address, buffer, num_bytes);
}

static void ejs_event_handler(const rc_client_event_t *event, rc_client_t *client)
{
   (void)client;
   switch (event->type)
   {
      case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
         emit_achievement("achievement_triggered", event->achievement, 0);
         break;
      case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
         emit_achievement("challenge_show", event->achievement, 0);
         break;
      case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
         emit_achievement("challenge_hide", event->achievement, 0);
         break;
      case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
         emit_achievement("progress_show", event->achievement, 1);
         break;
      case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
         emit_achievement("progress_update", event->achievement, 1);
         break;
      case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE:
         emit_simple("progress_hide");
         break;
      case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
         emit_leaderboard("leaderboard_started", event->leaderboard, 0);
         break;
      case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
         emit_leaderboard("leaderboard_failed", event->leaderboard, 0);
         break;
      case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
         emit_leaderboard("leaderboard_submitted", event->leaderboard, 1);
         break;
      case RC_CLIENT_EVENT_GAME_COMPLETED:
      {
         ejs_buf_t buf = {0};
         buf_put(&buf, "{\"type\":\"game_completed\",\"hardcore\":");
         buf_put(&buf, rc_client_get_hardcore_enabled(ejs_client) ? "true" : "false");
         buf_put(&buf, "}");
         ejs_emit(&buf);
         break;
      }
      case RC_CLIENT_EVENT_SERVER_ERROR:
         emit_message("server_error", event->server_error ? event->server_error->error_message : "");
         break;
      case RC_CLIENT_EVENT_DISCONNECTED:
         emit_simple("disconnected");
         break;
      case RC_CLIENT_EVENT_RECONNECTED:
         emit_simple("reconnected");
         break;
      case RC_CLIENT_EVENT_RESET:
         emit_simple("reset");
         break;
      default:
         break;
   }
}

/* ---------- HTTP pelo site ---------- */

static void ejs_server_call(const rc_api_request_t *request,
      rc_client_server_callback_t callback, void *callback_data, rc_client_t *client)
{
   int id;
   (void)client;
   for (id = 0; id < EJS_CHEEVOS_MAX_PENDING; ++id)
      if (!ejs_pending[id].used)
         break;
   if (id == EJS_CHEEVOS_MAX_PENDING)
   {
      rc_api_server_response_t response;
      response.body = "Muitos pedidos pendentes.";
      response.body_length = strlen(response.body);
      response.http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
      callback(&response, callback_data);
      return;
   }
   ejs_pending[id].used = 1;
   ejs_pending[id].callback = callback;
   ejs_pending[id].callback_data = callback_data;
   EM_ASM({
      if (Module.ejsCheevosHttp)
         Module.ejsCheevosHttp(UTF8ToString($0), $1 ? UTF8ToString($1) : null, $2);
   }, request->url, request->post_data, id);
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_http_response(int id, int status, const char *body)
{
   rc_api_server_response_t response;
   rc_client_server_callback_t callback;
   void *callback_data;
   if (id < 0 || id >= EJS_CHEEVOS_MAX_PENDING || !ejs_pending[id].used)
      return;
   callback = ejs_pending[id].callback;
   callback_data = ejs_pending[id].callback_data;
   ejs_pending[id].used = 0;
   response.body = body ? body : "";
   response.body_length = strlen(response.body);
   /* Sem resposta do site (rede) = erro que o rc_client tenta de novo. */
   response.http_status_code = status > 0 ? status : RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
   callback(&response, callback_data);
}

/* ---------- Leitura de disco para o hash ----------
 * Igual ao cheevos.c do RetroArch: arquivos pelo intfstream e .chd pelo cdfs
 * (libchdr do libretro-common, com HAVE_CHD). Sem isso, o rc_hash não lê .chd
 * e os jogos de disco (PS1, Sega CD, PC Engine CD...) ficam sem conquistas. */

static void *ejs_file_open(const char *path)
{
   return intfstream_open_file(path, RETRO_VFS_FILE_ACCESS_READ, RETRO_VFS_FILE_ACCESS_HINT_NONE);
}

static void ejs_file_seek(void *handle, int64_t offset, int origin)
{
   intfstream_seek((intfstream_t*)handle, offset, origin);
}

static int64_t ejs_file_tell(void *handle)
{
   return intfstream_tell((intfstream_t*)handle);
}

static size_t ejs_file_read(void *handle, void *buffer, size_t requested_bytes)
{
   return intfstream_read((intfstream_t*)handle, buffer, requested_bytes);
}

static void ejs_file_close(void *handle)
{
   intfstream_close((intfstream_t*)handle);
   free(handle);
}

#ifdef HAVE_CHD
static void *ejs_chd_open_track(const char *path, uint32_t track)
{
   cdfs_track_t *cdfs_track;
   switch (track)
   {
      case RC_HASH_CDTRACK_FIRST_DATA:
         cdfs_track = cdfs_open_data_track(path);
         break;
      case RC_HASH_CDTRACK_LAST:
         cdfs_track = cdfs_open_track(path, CHDSTREAM_TRACK_LAST);
         break;
      case RC_HASH_CDTRACK_LARGEST:
         cdfs_track = cdfs_open_track(path, CHDSTREAM_TRACK_PRIMARY);
         break;
      default:
         cdfs_track = cdfs_open_track(path, track);
         break;
   }
   if (cdfs_track)
   {
      cdfs_file_t *file = (cdfs_file_t*)malloc(sizeof(cdfs_file_t));
      if (cdfs_open_file(file, cdfs_track, NULL))
         return file; /* o file passa a ser dono do cdfs_track */
      free(file);
      cdfs_close_track(cdfs_track);
   }
   return NULL;
}

static size_t ejs_chd_read_sector(void *handle, uint32_t sector, void *buffer, size_t requested_bytes)
{
   cdfs_file_t *file = (cdfs_file_t*)handle;
   uint32_t track_sectors = cdfs_get_num_sectors(file);
   sector -= cdfs_get_first_sector(file);
   if (sector >= track_sectors)
      return 0;
   cdfs_seek_sector(file, sector);
   return cdfs_read_file(file, buffer, requested_bytes);
}

static uint32_t ejs_chd_first_track_sector(void *handle)
{
   return cdfs_get_first_sector((cdfs_file_t*)handle);
}

static void ejs_chd_close_track(void *handle)
{
   cdfs_file_t *file = (cdfs_file_t*)handle;
   if (file)
   {
      cdfs_close_track(file->track);
      cdfs_close_file(file); /* não libera o file */
      free(file);
   }
}
#endif

static void *ejs_cd_open_track(const char *path, uint32_t track, const rc_hash_iterator_t *iterator)
{
   rc_hash_callbacks_t *callbacks = (rc_hash_callbacks_t*)&iterator->callbacks;
   callbacks->filereader.open = ejs_file_open;
   callbacks->filereader.seek = ejs_file_seek;
   callbacks->filereader.tell = ejs_file_tell;
   callbacks->filereader.read = ejs_file_read;
   callbacks->filereader.close = ejs_file_close;

   if (string_is_equal_noncase(path_get_extension(path), "chd"))
   {
#ifdef HAVE_CHD
      callbacks->cdreader.open_track_iterator = ejs_cd_open_track;
      callbacks->cdreader.read_sector = ejs_chd_read_sector;
      callbacks->cdreader.close_track = ejs_chd_close_track;
      callbacks->cdreader.first_track_sector = ejs_chd_first_track_sector;
      return ejs_chd_open_track(path, track);
#else
      return NULL;
#endif
   }
   {
      struct rc_hash_cdreader cdreader;
      rc_hash_get_default_cdreader(&cdreader);
      return cdreader.open_track_iterator(path, track, iterator);
   }
}

/* Log do rc_client (inclui o do hash) no console do navegador, com o prefixo [cheevos]. */
static void ejs_log(const char *message, const rc_client_t *client)
{
   (void)client;
   EM_ASM({ console.log('[cheevos] ' + UTF8ToString($0)); }, message);
}

static void ejs_init_hash_hooks(void)
{
   struct rc_hash_cdreader cdreader;
   rc_hash_get_default_cdreader(&cdreader);
   cdreader.open_track_iterator = ejs_cd_open_track;
   rc_hash_init_custom_cdreader(&cdreader);
}

/* ---------- Funções chamadas pelo site ---------- */

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_init(const char *user_agent_extension)
{
   (void)user_agent_extension; /* O User-Agent é posto pelo proxy da API. */
   if (ejs_client)
      return;
   memset(ejs_pending, 0, sizeof(ejs_pending));
   ejs_client = rc_client_create(ejs_read_memory, ejs_server_call);
   rc_client_set_event_handler(ejs_client, ejs_event_handler);
   rc_client_set_hardcore_enabled(ejs_client, 0);
   /* Avisos e erros (ex.: "Could not open track", conquista com endereço inválido). Para depurar, VERBOSE. */
   rc_client_enable_logging(ejs_client, RC_CLIENT_LOG_LEVEL_WARN, ejs_log);
   ejs_init_hash_hooks();
}

static void ejs_login_callback(int result, const char *error_message, rc_client_t *client, void *userdata)
{
   (void)client; (void)userdata;
   if (result == RC_OK)
      emit_simple("logged_in");
   else
      emit_message("login_failed", error_message ? error_message : "login");
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_login_token(const char *username, const char *token)
{
   if (!ejs_client)
      ejs_cheevos_init("");
   rc_client_begin_login_with_token(ejs_client, username, token, ejs_login_callback, NULL);
}

static void ejs_load_callback(int result, const char *error_message, rc_client_t *client, void *userdata)
{
   const rc_client_game_t *game;
   rc_client_user_game_summary_t summary;
   ejs_buf_t buf = {0};
   (void)userdata;

   game = rc_client_get_game_info(client);
   if (result == RC_NO_GAME_LOADED || (result == RC_OK && (!game || game->id == 0)))
   {
      emit_simple("game_unsupported");
      return;
   }
   if (result != RC_OK)
   {
      emit_message("load_failed", error_message ? error_message : "load");
      return;
   }
   /* Com o console certo, o mapa de memória pode mudar (ex.: regiões extras). */
   ejs_init_memory(game->console_id);
   rc_client_get_user_game_summary(client, &summary);
   buf_put(&buf, "{\"type\":\"game_loaded\",\"title\":");
   buf_str(&buf, game->title);
   buf_put(&buf, ",\"total\":");
   buf_num(&buf, summary.num_core_achievements);
   buf_put(&buf, ",\"unlocked\":");
   buf_num(&buf, summary.num_unlocked_achievements);
   buf_put(&buf, ",\"hardcore\":");
   buf_put(&buf, rc_client_get_hardcore_enabled(client) ? "true" : "false");
   buf_put(&buf, "}");
   ejs_emit(&buf);
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_load_game(int console_id)
{
   const char *path = path_get(RARCH_PATH_CONTENT);
   if (!ejs_client || !path || !*path)
   {
      emit_message("load_failed", "Jogo não carregado.");
      return;
   }
   ejs_init_memory((uint32_t)console_id);
   rc_client_begin_identify_and_load_game(ejs_client, (uint32_t)console_id, path, NULL, 0, ejs_load_callback, NULL);
}

/* Carrega pelo hash que o site já tem (o raHash do catálogo, calculado pelo RAHasher no servidor), sem ler o
 * arquivo: para o PSP, cujo disco é lido sob demanda, e para quando o hash no navegador falha. */
EMSCRIPTEN_KEEPALIVE void ejs_cheevos_load_game_hash(int console_id, const char *hash)
{
   if (!ejs_client || !hash || !*hash)
   {
      emit_message("load_failed", "Sem o hash do jogo.");
      return;
   }
   ejs_init_memory((uint32_t)console_id);
   rc_client_begin_load_game(ejs_client, hash, ejs_load_callback, NULL);
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_set_hardcore(int enabled)
{
   if (ejs_client)
      rc_client_set_hardcore_enabled(ejs_client, enabled ? 1 : 0);
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_reset(void)
{
   if (ejs_client)
      rc_client_reset(ejs_client);
}

/* Carregou um save state: o estado não leva o progresso do rcheevos, então zera. */
EMSCRIPTEN_KEEPALIVE void ejs_cheevos_reset_progress(void)
{
   if (ejs_client)
      rc_client_deserialize_progress_sized(ejs_client, NULL, 0);
}

/* Troca de disco: o arquivo do disco novo já está no FS; o rc_client confere o hash. */
EMSCRIPTEN_KEEPALIVE void ejs_cheevos_change_media(int disc)
{
   const char *path = path_get(RARCH_PATH_CONTENT);
   (void)disc;
   if (ejs_client && path && *path)
      rc_client_begin_identify_and_change_media(ejs_client, path, NULL, 0, NULL, NULL);
}

EMSCRIPTEN_KEEPALIVE void ejs_cheevos_unload(void)
{
   int i;
   if (!ejs_client)
      return;
   rc_client_unload_game(ejs_client);
   /* Pedidos ainda no site: o callback não é mais chamado. */
   for (i = 0; i < EJS_CHEEVOS_MAX_PENDING; ++i)
      ejs_pending[i].used = 0;
   if (ejs_memory_ready)
   {
      rc_libretro_memory_destroy(&ejs_memory);
      ejs_memory_ready = 0;
   }
}

/* Chamado pelo runloop depois de cada quadro emulado. */
void ejs_cheevos_do_frame(void)
{
   if (ejs_client)
      rc_client_do_frame(ejs_client);
}

/* Pausado ou no menu: mantém o ping e as filas do rc_client. */
void ejs_cheevos_idle(void)
{
   if (ejs_client)
      rc_client_idle(ejs_client);
}

#endif /* EMULATORJS_CHEEVOS */
