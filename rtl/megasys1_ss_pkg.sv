// Save-state constants: DDRAM base and the stream chunk index of each saved block.
package megasys1_ss_pkg;
    parameter bit [31:0] SS_DDR_BASE = 32'h3E00_0000;

    parameter int SSIDX_GLOBAL    = 0;
    parameter int SSIDX_MAIN_RAM  = 1;
    parameter int SSIDX_SOUND_RAM = 2;
    parameter int SSIDX_SPR_RAM   = 3;
    parameter int SSIDX_SCR0_RAM  = 4;
    parameter int SSIDX_SCR1_RAM  = 5;
    parameter int SSIDX_SCR2_RAM  = 6;
    parameter int SSIDX_PAL_RAM   = 7;
    parameter int SSIDX_FRAMEBUF  = 8;
    parameter int SSIDX_MISC      = 9;
    parameter int SSIDX_OPM_REGS  = 10;
    parameter int SSIDX_OPM_MISC  = 11;
    parameter int SSIDX_COUNT     = 12;
endpackage

import megasys1_ss_pkg::*;
