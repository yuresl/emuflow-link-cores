# Liga o cabo dos portateis ao site (Module.emuflowSerial). python3 apply-hh.py <ngp|wswan|handy|gg> <raiz>
import re
import sys

core, root = sys.argv[1], sys.argv[2]


def sub(path, pairs):
    p = f'{root}/{path}'
    s = open(p, newline='').read()
    crlf = '\r\n' in s
    s = s.replace('\r\n', '\n')
    for old, new in pairs:
        assert s.count(old) >= 1, (path, old[:70])
        s = s.replace(old, new, 1)
    if crlf:
        s = s.replace('\n', '\r\n')
    open(p, 'w', newline='').write(s)


TX = "EM_ASM({ var w = Module['emuflowSerial']; if (w) w['tx']($0); }, %s)"
RX = "EM_ASM_INT({ var w = Module['emuflowSerial']; return w ? w['rx']() : -1; })"
PEEK = "EM_ASM_INT({ var w = Module['emuflowSerial']; return w ? w['peek']() : -1; })"
HAS = "EM_ASM_INT({ return Module['emuflowSerial'] ? 1 : 0; })"
SYNC = "EM_ASM({ var w = Module['emuflowSerial']; if (w) w['sync']($0); }, %s)"

if core == 'ngp':
    # O core so grava o save ao descarregar o jogo, o que nunca acontece no navegador: grava logo depois que o jogo escreve.
    sub('mednafen/ngp/flash.c', [(
        'void flash_write(uint32_t start_address, uint16_t length)\n{\n   uint16_t i;\n',
        'int flash_dirty_frames = 0;\n\nvoid flash_write(uint32_t start_address, uint16_t length)\n{\n   uint16_t i;\n\n   flash_dirty_frames = 60;\n',
    )])
    sub('libretro.c', [(
        'void retro_run(void)\n{\n',
        'extern int flash_dirty_frames;\nextern void flash_commit(void);\n\nvoid retro_run(void)\n{\n'
        '   if (flash_dirty_frames > 0 && --flash_dirty_frames == 0)\n      flash_commit();\n\n',
    )])
    sub('mednafen/ngp/system.c', [(
        '''bool system_comms_read(uint8_t* buffer) { return 0; }
bool system_comms_poll(uint8_t* buffer) { return 0; }
void system_comms_write(uint8_t data) { }
''',
        '''/* EmuFlow: o cabo passa pelo site (Module.emuflowSerial). */
#include <emscripten.h>
bool system_comms_read(uint8_t* buffer)
{
   int value = buffer ? %s : %s;
   if (value < 0)
      return 0;
   if (buffer)
      *buffer = (uint8_t)value;
   return 1;
}
bool system_comms_poll(uint8_t* buffer)
{
   int value = %s;
   if (value < 0)
      return 0;
   if (buffer)
      *buffer = (uint8_t)value;
   return 1;
}
void system_comms_write(uint8_t data) { %s; }
''' % (RX, PEEK, PEEK, TX % 'data'),
    ), (
        '''bool system_io_flash_read(''',
        '''void system_comms_line(void)
{
   static int lines;
   lines++;
   %s;
}

bool system_io_flash_read(''' % (SYNC % 'lines'),
    )])
    sub('mednafen/ngp/system.h', [(
        'void system_comms_write(uint8_t data);',
        'void system_comms_write(uint8_t data);\n\n/* EmuFlow: uma vez por linha, para os dois consoles andarem juntos. */\nvoid system_comms_line(void);',
    )])
    sub('mednafen/ngp/interrupt.c', [(
        '''      /* Comms. Read interrupt */
      if ((COMMStatus & 1) == 0 && system_comms_poll(&_data))''',
        '''      system_comms_line();

      /* Comms. Read interrupt */
      if ((COMMStatus & 1) == 0 && system_comms_poll(&_data))''',
    )])
    # A BIOS guarda em 0x6D01 quantos bytes ha para ler: a interrupcao soma e o GET subtrai. Os jogos consultam esse
    # contador antes de chamar o GET. Na BIOS emulada ele so subia, e aos 256 bytes voltava a 0, ou seja, "fila vazia".
    sub('mednafen/ngp/biosHLE.c', [("""            if (system_comms_read(&data))
            {
               rCodeB(0x30) = 0;	//COM_BUF_OK
""", """            if (system_comms_read(&data))
            {
               if (loadB(0x6D01)) storeB(0x6D01, loadB(0x6D01) - 1); /* EmuFlow */
               rCodeB(0x30) = 0;	//COM_BUF_OK
"""), ("""            /* Read data into (XHL3++) */
""", """            if (loadB(0x6D01)) storeB(0x6D01, loadB(0x6D01) - 1); /* EmuFlow */
            /* Read data into (XHL3++) */
""")])
    import os
    if os.environ.get('HHDBG'):
        sub('mednafen/ngp/interrupt.c', [("""      system_comms_line();
""", """      system_comms_line();
      EM_ASM({ var f = Module['__pc']; if (f) f($0, $1, $2); }, pc & 0xFFFFFF, (int)CPUExRAM, (int)REGXSP);
"""), ("""#include "interrupt.h"
""", """#include "interrupt.h"
#include <emscripten/em_asm.h>
extern uint8_t CPUExRAM[];
#include "TLCS-900h/TLCS900h_registers.h"
""")])
        sub('mednafen/ngp/mem.c', [("""   switch (address)
   {
      case 0x50:
         return SC0BUF;
""", """   if (address < 0x100) EM_ASM({ var f = Module['__io']; if (f) f($0, -1); }, address);
   switch (address)
   {
      case 0x50:
         return SC0BUF;
"""), ("""   switch (address)
   {
      case 0x50:
         SC0BUF = data;
""", """   if (address < 0x100) EM_ASM({ var f = Module['__io']; if (f) f($0, $1); }, address, data);
   switch (address)
   {
      case 0x50:
         SC0BUF = data;
"""), ("""#include "mem.h"
""", """#include "mem.h"
#include <emscripten/em_asm.h>
""")])
        sub('mednafen/ngp/biosHLE.c', [("""   cycles = 8;		/* TODO: Correct cycle counts (or approx?) */
""", """   cycles = 8;		/* TODO: Correct cycle counts (or approx?) */
   if ((pc & 0xFFF000) == 0xFF2000) EM_ASM({ var f = Module['__bios']; if (f) f($0); }, pc & 0xFFFFFF);
"""), ("""#include "../state.h"
""", """#include "../state.h"
#include <emscripten/em_asm.h>
""")])
elif core == 'wswan':
    sub('mednafen/wswan/comm.c', [
        ('''#include <string.h>

#include "wswan.h"''', '''#include <string.h>
#include <emscripten.h>

#include "wswan.h"'''),
        ('''static bool SendLatched, RecvLatched;
''', '''static bool SendLatched, RecvLatched;
/* EmuFlow: um byte leva 12,5 linhas a 9600 bps e 3 a 38400. */
static int SendLines;
'''),
        ('''   if(SendLatched && (Control & 0x80))
   {
      /* No link peer; the byte leaves the shift register
       * immediately. */
      SendLatched = false;
      WSwan_Interrupt(WSINT_SERIAL_SEND);
   }
''', '''   {
      static int lines;
      lines++;
      %s;
   }

   if(SendLatched && (Control & 0x80))
   {
      if(SendLines > 0)
         SendLines--;
      else
      {
         /* EmuFlow: o cabo passa pelo site (Module.emuflowSerial). */
         %s;
         SendLines = (Control & 0x40) ? 3 : 12;
         SendLatched = false;
         WSwan_Interrupt(WSINT_SERIAL_SEND);
      }
   }

   /* EmuFlow: o bit 7 liga a porta (wstech24.txt); os jogos escrevem 0x80 e 0xC0, sem o 0x20. */
   if((Control & 0x80) && !RecvLatched)
   {
      int value = %s;
      if(value >= 0)
      {
         RecvBuf = (uint8)value;
         RecvLatched = true;
         WSwan_InterruptAssert(WSINT_SERIAL_RECV, RecvLatched);
      }
   }
''' % (SYNC % 'lines', TX % 'SendBuf', RX)),
        ('''      if((Control & 0x20) && RecvLatched)
         ret |= 0x1;
''', '''      if(RecvLatched)
         ret |= 0x1;
'''),
    ])
elif core == 'handy':
    sub('lynx/mikie.cpp', [(
        '''            //
            // Receive
            //
            if(!mUART_RX_COUNTDOWN) {''',
        '''            // EmuFlow: um byte de cada vez. Com dois na fila, o Handy espera UART_RX_NEXT_DELAY entre eles, mais que o
            // limite entre bytes dos jogos, e o pacote chega picado
            if(mUART_Rx_waiting==0) {
               int incoming=%s;
               if(incoming>=0) {
                  // Os dois no fio ao mesmo tempo: no aparelho, o byte chega estragado, e o jogo sorteia outro atraso.
                  // Se ficasse na fila, seria lido depois como o inicio de um pacote.
                  if(mUART_TX_IRQ_ENABLE || !(mUART_TX_COUNTDOWN&UART_TX_INACTIVE)) mUART_Rx_framing_error=1;
                  else ComLynxRxData(incoming);
               }
            }

            //
            // Receive
            //
            if(!mUART_RX_COUNTDOWN) {''' % RX,
    ), ('''         mUART_TX_DATA=data;
         // Calculate Parity data
         if(mUART_PARITY_ENABLE) {
            // Calc parity value
            // Leave at zero !!
         } else {
            // If disabled then the PAREVEN bit is sent
            if(mUART_PARITY_EVEN) data|=0x0100;
         }
''', '''         mUART_TX_DATA=data;
         // EmuFlow: o nono bit vai junto, como no aparelho. Sem ele, quem recebe sempre via paridade zero
         if(mUART_PARITY_ENABLE) {
            int ones=0;
            for(int bit=0;bit<8;bit++) ones+=(data>>bit)&1;
            if((ones&1)==(mUART_PARITY_EVEN?1:0)) mUART_TX_DATA|=0x0100;
         } else if(mUART_PARITY_EVEN) {
            // If disabled then the PAREVEN bit is sent
            mUART_TX_DATA|=0x0100;
         }
'''), ('''#include <stdio.h>''', '''#include <emscripten.h>
#include <stdio.h>''')])
    import os
    if os.environ.get('HHDBG'):
        sub('lynx/mikie.cpp', [('''         mUART_RX_READY=0;
         return (UBYTE)(mUART_RX_DATA&0xff);''', '''         EM_ASM({ var l = Module['__serLog'] = Module['__serLog'] || []; if (l.length < 4000) l.push($0, $1, $2); }, mUART_RX_DATA, mUART_RX_READY, mUART_Rx_waiting);
         mUART_RX_READY=0;
         return (UBYTE)(mUART_RX_DATA&0xff);''')])
    # Timer rearmado depois de terminar conta a partir de agora, e nao de quando parou.
    sub('lynx/mikie.cpp', [(f'''         mTIM_{n}_TIMER_DONE=data&0x08;
''', f'''         if(mTIM_{n}_TIMER_DONE && !(data&0x08)) mTIM_{n}_LAST_COUNT=gSystemCycleCount; // EmuFlow
         mTIM_{n}_TIMER_DONE=data&0x08;
''') for n in range(8)])
    p = f'{root}/lynx/mikie.h'
    h = open(p, newline='').read()
    h, n = re.subn(r'(#define\s+UART_RX_NEXT_DELAY\s+)\(?\d+\)?', r'\g<1>(0)', h)
    assert n == 1
    open(p, 'w', newline='').write(h)
    sub('libretro/libretro.cpp', [
        ('''#include "handy.h"
''', '''#include "handy.h"
#include <emscripten.h>

/* EmuFlow: o ComLynx passa pelo site (Module.emuflowSerial). */
static void emuflow_comlynx_tx(int data, ULONG)
{
   %s;
}
''' % (TX % 'data')),
        ('''      lynx->Update();
''', '''      {
         static ULONG lastTick;
         ULONG tick = gSystemCycleCount >> 10;
         if (tick != lastTick)
         {
            lastTick = tick;
            %s;
         }
      }
      lynx->Update();
''' % (SYNC % '(int)tick')),
        ('''   lynx->SetButtonData(res);
''', '''   lynx->SetButtonData(res);
   lynx->ComLynxTxCallback(emuflow_comlynx_tx, 0);
'''),
    ])
elif core == 'gg':
    sub('core/io_ctrl.c', [
        ('''#include "shared.h"
''', '''#include "shared.h"
#include <emscripten/em_asm.h>

/*
 * EmuFlow: Gear-to-Gear pelo site (Module.emuflowSerial). A serial e o que os jogos usam: 8 bits, com NMI na
 * recepcao. No paralelo, os pinos sao cruzados (smspower.org/Development/GearToGearCable).
 */
static const int gg_lines_per_byte[4] = { 33, 66, 131, 525 };
static int gg_send_lines;
static int gg_receive_lines;

static void gg_publish_pins(void)
{
  int pins = (io_reg[1] | io_reg[2]) & 0x7F;
  EM_ASM({ var w = Module['emuflowSerial']; if (w) w['setPins']($0); }, pins);
}

static unsigned int gg_read_pins(void)
{
  int peer = EM_ASM_INT({ var w = Module['emuflowSerial']; return w ? w['pins']() : 0x7F; });
  return ((peer & 1) << 2) | ((peer & 2) << 2) | ((peer & 4) >> 2) | ((peer & 8) >> 2)
    | ((peer & 0x10) << 1) | ((peer & 0x20) >> 1) | (peer & 0x40);
}

/* Uma vez por linha. */
void io_gg_line(void)
{
  static int lines;
  if (system_hw != SYSTEM_GG)
    return;
  lines++;
  %s;
  if (gg_send_lines > 0 && --gg_send_lines == 0)
    io_reg[5] &= ~0x01;
  if (gg_receive_lines > 0)
    gg_receive_lines--;
  else if ((io_reg[5] & 0x20) && !(io_reg[5] & 0x02))
  {
    int value = %s;
    if (value >= 0)
    {
      io_reg[4] = value;
      io_reg[5] |= 0x02;
      gg_receive_lines = gg_lines_per_byte[io_reg[5] >> 6];
      if (io_reg[5] & 0x08)
      {
        z80_set_nmi_line(ASSERT_LINE);
        z80_set_nmi_line(CLEAR_LINE);
      }
    }
  }
}
''' % (SYNC % 'lines', RX)),
        ('''    case 1: /* Parallel data register */
      io_reg[1] = data;
      return;
''', '''    case 1: /* Parallel data register */
      io_reg[1] = data;
      gg_publish_pins();
      return;
'''),
        ('''    case 2: /* Data direction register and NMI enable */
      io_reg[2] = data;
      return;
''', '''    case 2: /* Data direction register and NMI enable */
      io_reg[2] = data;
      gg_publish_pins();
      return;
'''),
        ('''    case 3: /* Transmit data buffer */
      io_reg[3] = data;
      return;
''', '''    case 3: /* Transmit data buffer */
      io_reg[3] = data;
      if ((io_reg[5] & 0x10) && !gg_send_lines)
      {
        %s;
        if (%s)
        {
          io_reg[5] |= 0x01;
          gg_send_lines = gg_lines_per_byte[io_reg[5] >> 6];
        }
      }
      return;
''' % (TX % 'data', HAS)),
        ('''      io_reg[5] = data & 0xF8;
''', '''      io_reg[5] = (data & 0xF8) | (io_reg[5] & 0x03);
'''),
        ('''    case 1: /* Parallel data register (not connected) */
      return ((io_reg[1] & ~(io_reg[2] & 0x7F)) | (io_reg[2] & 0x7F));
''', '''    case 1: /* Parallel data register */
      return ((io_reg[1] & ~(io_reg[2] & 0x7F)) | (gg_read_pins() & io_reg[2] & 0x7F));
'''),
        ('''    case 4: /* Receive data buffer */
      return io_reg[4];
''', '''    case 4: /* Receive data buffer */
      io_reg[5] &= ~0x02;
      return io_reg[4];
'''),
    ])
    sub('core/io_ctrl.h', [(
        'extern unsigned int io_gg_read(unsigned int offset);',
        'extern unsigned int io_gg_read(unsigned int offset);\nextern void io_gg_line(void);',
    )])
    p = f'{root}/core/system.c'
    s = open(p, newline='').read()
    i = s.index('void system_frame_sms(int do_skip)')
    head, tail = s[:i], s[i:]
    tail, n = re.subn(r'(\n[ \t]*)(z80_run\((?:mcycles_vdp \+ )?MCYCLES_PER_LINE\);)', r'\1io_gg_line();\1\2', tail)
    assert n >= 3, n
    open(p, 'w', newline='').write(head + tail)
else:
    raise SystemExit('core?')
print('ok', core)
