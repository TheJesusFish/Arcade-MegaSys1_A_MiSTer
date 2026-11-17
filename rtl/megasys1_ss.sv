// Per-CPU save-state helper: forced level 7 interrupt, handler/vector override and stack pointer capture.
module megasys1_ss_cpu (
    input             clk,
    input             reset,

    input      [23:1] a,
    input             as_n,
    input             rw,
    input             uds_n,
    input             lds_n,
    input       [2:0] fc,
    input      [15:0] dout,

    input             start_save,
    input             start_restore,
    input             drop_irq,
    input             clear,
    input      [31:0] ssp_in,

    output reg        irq,
    output reg        ovr,
    output            hit,
    output reg [15:0] hit_data,
    output reg        parked,
    output reg [31:0] ssp
);

wire ds     = ~( uds_n & lds_n );
wire in_hdl = ( a[23:5] == 19'h7f800 );   // handler, 0xff0000-0xff001f
wire in_rst = ( a[23:3] == 21'd0 );       // reset vectors, 0x000000-0x000007
wire in_vec = ( a[23:2] == 22'h1f );      // level 7 autovector, 0x00007c-0x00007f

assign hit = ovr & ( in_hdl | in_rst | in_vec );

// handler: push d0-a6 and usp, store ssp at 0xff0000; restart point 0xff0008 pops them and returns
always @* begin
    case ( a[4:1] )
        4'h0: hit_data = 16'h48e7;   // movem.l d0-d7/a0-a6,-(a7)
        4'h1: hit_data = 16'hfffe;
        4'h2: hit_data = 16'h4e6e;   // move.l usp,a6
        4'h3: hit_data = 16'h2f0e;   // move.l a6,-(a7)
        4'h4: hit_data = 16'h4df9;   // lea $ff0000,a6
        4'h5: hit_data = 16'h00ff;
        4'h6: hit_data = 16'h0000;
        4'h7: hit_data = 16'h2c8f;   // move.l a7,(a6)
        4'h8: hit_data = 16'h2c5f;   // move.l (a7)+,a6
        4'h9: hit_data = 16'h4e66;   // move.l a6,usp
        4'ha: hit_data = 16'h4cdf;   // movem.l (a7)+,d0-d7/a0-a6
        4'hb: hit_data = 16'h7fff;
        4'hc: hit_data = 16'h4e73;   // rte
        default: hit_data = 16'h0000;
    endcase
    if ( in_rst ) begin
        case ( a[2:1] )
            2'd0: hit_data = ssp_in[31:16];
            2'd1: hit_data = ssp_in[15:0];
            2'd2: hit_data = 16'h00ff;
            2'd3: hit_data = 16'h0008;
        endcase
    end else if ( in_vec ) begin
        hit_data = a[1] ? 16'h0000 : 16'h00ff;
    end
end

always @(posedge clk) begin
    if ( reset ) begin
        irq    <= 0;
        ovr    <= 0;
        parked <= 0;
    end else begin
        if ( start_save )    begin irq <= 1; parked <= 0; end
        if ( start_restore ) begin ovr <= 1; parked <= 0; end
        if ( irq && !as_n && fc == 3'b111 && a[3:1] == 3'b111 ) begin
            irq <= 0;
            ovr <= 1;
        end
        if ( ovr && !as_n && !rw && ds && in_hdl ) begin
            if ( a[4:1] == 4'd0 ) ssp[31:16] <= dout;
            if ( a[4:1] == 4'd1 ) begin ssp[15:0] <= dout; parked <= 1; end
        end
        if ( ovr && !as_n && rw && ds && fc[1:0] == 2'b10 && !( in_hdl | in_rst | in_vec ) ) ovr <= 0;
        if ( drop_irq ) irq <= 0;
        if ( clear ) begin irq <= 0; ovr <= 0; end
    end
end

endmodule


// Save-state sequencer: parks both CPUs at a fixed raster point, streams the state, resumes at the same raster point.
module megasys1_ss_ctrl (
    input             clk,
    input             reset,
    input             do_save,
    input             do_restore,

    input       [8:0] vc,
    input       [8:0] hc,
    input       [7:0] c6,
    input             vbl,
    input             sprite_idle,
    input             s_in_reset,

    input             parked_p,
    input             parked_s,
    input             ovr_p,
    input             ovr_s,
    input      [31:0] ssp_p,
    input      [31:0] ssp_s,

    output reg        start_save_p,
    output reg        start_save_s,
    output reg        start_restore_p,
    output reg        start_restore_s,
    output reg        drop_irq,
    output reg        clear_ovr,
    output reg [31:0] ssp_in_p,
    output reg [31:0] ssp_in_s,

    output reg        halt_p,
    output reg        halt_s,
    output reg        halt_snd,
    output reg        halt_vid,
    output reg        exec_p,
    output reg        rst_p,
    output reg        rst_s,
    output reg        oki_rst,

    output reg        opm_replay,
    input             opm_busy,

    output reg        ss_write,
    output reg        ss_read,
    input             ss_busy,

    output            active,

    ssbus_if.slave    ssbus
);

localparam [15:0] MAGIC = 16'h4d31;

typedef enum logic [3:0] {
    IDLE, S_WAIT_R, S_PARK, S_STREAM, S_STREAM_WAIT, S_RESUME, S_EXIT,
    R_WAIT_R, R_STREAM, R_STREAM_WAIT, R_OPM, R_OPM_WAIT, R_RESET, R_RUN, R_RESUME
} state_t;

state_t     st = IDLE;
reg  [21:0] timer;
reg   [8:0] rf_vc;
reg   [8:0] rf_hc;
reg   [7:0] rf_c6;
reg         s_skip;
reg         magic_ok;
reg  [15:0] rd;

wire at_r  = sprite_idle && !vbl && vc < 9'd208;
wire at_rf = vc == rf_vc && hc == rf_hc && c6 == rf_c6;

assign active = ( st != IDLE );

always @* begin
    halt_p   = 0;
    halt_s   = 0;
    halt_snd = 0;
    halt_vid = 0;
    exec_p   = 0;
    rst_p    = 0;
    rst_s    = 0;
    oki_rst  = 0;
    case ( st )
        S_PARK: begin
            halt_p = parked_p;
            halt_s = parked_s | s_skip;
            exec_p = ~parked_p;
        end
        S_STREAM, S_STREAM_WAIT, S_RESUME, R_STREAM, R_STREAM_WAIT, R_OPM, R_OPM_WAIT, R_RESUME: begin
            halt_p   = 1;
            halt_s   = 1;
            halt_snd = 1;
            halt_vid = 1;
            oki_rst  = ( st == R_STREAM_WAIT );
        end
        R_RESET: begin
            halt_snd = 1;
            halt_vid = 1;
            rst_p    = 1;
            rst_s    = ~s_skip;
            exec_p   = 1;
        end
        R_RUN: begin
            halt_p   = parked_p;
            halt_s   = parked_s | s_skip;
            halt_snd = 1;
            halt_vid = 1;
            exec_p   = ~parked_p;
        end
        S_EXIT: begin
            exec_p = ovr_p;
        end
        default: ;
    endcase
end

always @* begin
    case ( ssbus.addr[3:0] )
        4'd0:    rd = ssp_p[31:16];
        4'd1:    rd = ssp_p[15:0];
        4'd2:    rd = ssp_s[31:16];
        4'd3:    rd = ssp_s[15:0];
        4'd4:    rd = { 7'd0, rf_vc };
        4'd5:    rd = { 7'd0, rf_hc };
        4'd6:    rd = { 8'd0, rf_c6 };
        4'd7:    rd = { 15'd0, s_skip };
        default: rd = MAGIC;
    endcase
end

always @(posedge clk) begin
    start_save_p    <= 0;
    start_save_s    <= 0;
    start_restore_p <= 0;
    start_restore_s <= 0;
    drop_irq        <= 0;
    clear_ovr       <= 0;
    opm_replay      <= 0;
    ss_write        <= 0;
    ss_read         <= 0;

    // global chunk: stack pointers, raster point, sound CPU reset flag, layout tag
    ssbus.setup(SSIDX_GLOBAL, 32'd9, 1);
    if ( ssbus.access(SSIDX_GLOBAL) ) begin
        if ( ssbus.read ) begin
            ssbus.read_response(SSIDX_GLOBAL, { 48'd0, rd });
        end else if ( ssbus.write ) begin
            case ( ssbus.addr[3:0] )
                4'd0: ssp_in_p[31:16] <= ssbus.data[15:0];
                4'd1: ssp_in_p[15:0]  <= ssbus.data[15:0];
                4'd2: ssp_in_s[31:16] <= ssbus.data[15:0];
                4'd3: ssp_in_s[15:0]  <= ssbus.data[15:0];
                4'd4: rf_vc           <= ssbus.data[8:0];
                4'd5: rf_hc           <= ssbus.data[8:0];
                4'd6: rf_c6           <= ssbus.data[7:0];
                4'd7: s_skip          <= ssbus.data[0];
                4'd8: magic_ok        <= ( ssbus.data[15:0] == MAGIC );
                default: ;
            endcase
            ssbus.write_ack(SSIDX_GLOBAL);
        end
    end

    if ( reset ) begin
        st <= IDLE;
    end else begin
        case ( st )
            IDLE: begin
                timer <= 0;
                if ( do_save )         st <= S_WAIT_R;
                else if ( do_restore ) st <= R_WAIT_R;
            end

            S_WAIT_R: if ( at_r ) begin
                s_skip       <= s_in_reset;
                start_save_p <= 1;
                start_save_s <= ~s_in_reset;
                timer        <= 0;
                st           <= S_PARK;
            end

            S_PARK: begin
                timer <= timer + 1'd1;
                if ( parked_p && ( parked_s || s_skip ) ) begin
                    rf_vc    <= vc;
                    rf_hc    <= hc;
                    rf_c6    <= c6;
                    ss_write <= 1;
                    st       <= S_STREAM;
                end else if ( &timer ) begin
                    drop_irq <= 1;
                    timer    <= 0;
                    st       <= S_EXIT;
                end
            end

            S_STREAM:      if ( ss_busy )  st <= S_STREAM_WAIT;
            S_STREAM_WAIT: if ( !ss_busy ) st <= S_RESUME;
            S_RESUME:      if ( at_rf ) begin timer <= 0; st <= S_EXIT; end

            S_EXIT: begin
                timer <= timer + 1'd1;
                if ( !ovr_p && !ovr_s ) begin
                    st <= IDLE;
                end else if ( &timer ) begin
                    clear_ovr <= 1;
                    st        <= IDLE;
                end
            end

            R_WAIT_R: if ( at_r ) begin
                magic_ok <= 0;
                ss_read  <= 1;
                st       <= R_STREAM;
            end

            R_STREAM:      if ( ss_busy ) st <= R_STREAM_WAIT;
            R_STREAM_WAIT: if ( !ss_busy ) begin
                if ( magic_ok ) begin
                    opm_replay <= 1;
                    st         <= R_OPM;
                end else begin
                    timer <= 0;
                    st    <= S_EXIT;
                end
            end

            R_OPM:      if ( opm_busy ) st <= R_OPM_WAIT;
            R_OPM_WAIT: if ( !opm_busy ) begin
                start_restore_p <= 1;
                start_restore_s <= ~s_skip;
                timer           <= 0;
                st              <= R_RESET;
            end

            R_RESET: begin
                timer <= timer + 1'd1;
                if ( timer == 22'd4095 ) begin
                    timer <= 0;
                    st    <= R_RUN;
                end
            end

            // CPUs run the restart code up to the stack pointer store, where the save parked them
            R_RUN: begin
                timer <= timer + 1'd1;
                if ( parked_p && ( parked_s || s_skip ) ) begin
                    st <= R_RESUME;
                end else if ( &timer ) begin
                    timer <= 0;
                    st    <= S_EXIT;
                end
            end

            R_RESUME: if ( at_rf ) begin timer <= 0; st <= S_EXIT; end

            default: st <= IDLE;
        endcase
    end
end

endmodule


// Save-state access to one RAM port: stream address/data/write while selected, read data returned one cycle later.
module megasys1_ss_ram #(parameter AW = 10, parameter SS_IDX = -1) (
    input              clk,
    ssbus_if.slave     ssbus,
    output             sel,
    output    [AW-1:0] addr,
    output      [15:0] wdata,
    output             we,
    input       [15:0] rdata
);

wire [31:0] SIZE = 2**AW;

assign sel   = ssbus.access(SS_IDX);
assign addr  = ssbus.addr[AW-1:0];
assign wdata = ssbus.data[15:0];
assign we    = sel & ssbus.write;

reg read_delay = 0;

always @(posedge clk) begin
    ssbus.setup(SS_IDX, SIZE, 1);
    if ( sel ) begin
        if ( ssbus.write ) begin
            ssbus.write_ack(SS_IDX);
        end else if ( ssbus.read ) begin
            if ( read_delay ) ssbus.read_response(SS_IDX, { 48'd0, rdata });
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

endmodule


// YM2151 register shadow: records register writes, saves them, and replays them into the chip after a restore.
module megasys1_opm_shadow #(parameter SS_IDX_REGS = -1, parameter SS_IDX_MISC = -1) (
    input            clk,
    input            clr,
    input            wr,
    input            a0,
    input      [7:0] din,

    input            replay,
    output           busy,
    output reg       ym_wr,
    output reg       ym_a0,
    output reg [7:0] ym_din,
    input            ym_busy,

    ssbus_if.slave   ssb_regs,
    ssbus_if.slave   ssb_misc
);

reg   [7:0] regs [0:255];
reg   [7:0] cur_addr = 0;
reg  [31:0] keyon = 0;
reg   [6:0] pmd = 0;
reg   [6:0] amd = 0;
reg [255:0] valid = 0;

wire [309:0] misc_out;
wire         misc_wr;

auto_save_adaptor #(.N_BITS(310), .SS_IDX(SS_IDX_MISC)) misc_ss (
    .clk,
    .ssbus(ssb_misc),
    .bits_in({ valid, amd, pmd, keyon, cur_addr }),
    .bits_out(misc_out),
    .bits_wr(misc_wr)
);

// register file: written by the chip writes or the stream, read by the stream or the replay
wire       ss_sel = ssb_regs.access(SS_IDX_REGS);
reg  [7:0] rp_addr;
reg  [7:0] rd_q;
wire [7:0] wa = ss_sel ? ssb_regs.addr[7:0] : cur_addr;
wire       we = ss_sel ? ssb_regs.write : ( wr & a0 );
wire [7:0] wd = ss_sel ? ssb_regs.data[7:0] : din;

always @(posedge clk) begin
    if ( we ) regs[wa] <= wd;
    rd_q <= regs[ss_sel ? ssb_regs.addr[7:0] : rp_addr];
end

reg rdly = 0;
always @(posedge clk) begin
    ssb_regs.setup(SS_IDX_REGS, 32'd256, 1);
    if ( ss_sel ) begin
        if ( ssb_regs.write ) begin
            ssb_regs.write_ack(SS_IDX_REGS);
        end else if ( ssb_regs.read ) begin
            if ( rdly ) ssb_regs.read_response(SS_IDX_REGS, { 56'd0, rd_q });
            rdly <= 1;
        end
    end else begin
        rdly <= 0;
    end
end

// address latch, written-register map, per-channel key-on and PMD/AMD (both share register 0x19)
always @(posedge clk) begin
    if ( clr ) begin
        cur_addr <= 0;
        keyon    <= 0;
        pmd      <= 0;
        amd      <= 0;
        valid    <= 0;
    end else if ( misc_wr ) begin
        { valid, amd, pmd, keyon, cur_addr } <= misc_out;
    end else if ( wr ) begin
        if ( !a0 ) begin
            cur_addr <= din;
        end else begin
            valid[cur_addr] <= 1'b1;
            if ( cur_addr == 8'h08 ) keyon[ { din[2:0], 2'b00 } +: 4 ] <= din[6:3];
            if ( cur_addr == 8'h19 ) begin
                if ( din[7] ) pmd <= din[6:0];
                else          amd <= din[6:0];
            end
        end
    end
end

// replay order: 0x20-0xff, globals, timers and 0x14, AMD, PMD, key-on per channel, then the address latch
reg  [7:0] step;
reg  [7:0] s_reg;
reg        s_ram;
reg  [7:0] s_fixed;
reg        s_valid;
reg        s_addr_only;
wire [7:0] s_ch = step - 8'd234;

always @* begin
    s_ram       = 1;
    s_fixed     = 8'd0;
    s_addr_only = 0;
    s_reg       = 8'h00;
    if ( step < 8'd224 ) begin
        s_reg = 8'h20 + step;
    end else if ( step < 8'd232 ) begin
        case ( step[2:0] )
            3'd0: s_reg = 8'h01;
            3'd1: s_reg = 8'h0f;
            3'd2: s_reg = 8'h18;
            3'd3: s_reg = 8'h1b;
            3'd4: s_reg = 8'h10;
            3'd5: s_reg = 8'h11;
            3'd6: s_reg = 8'h12;
            3'd7: s_reg = 8'h14;
        endcase
    end else if ( step < 8'd234 ) begin
        s_reg   = 8'h19;
        s_ram   = 0;
        s_fixed = ( step == 8'd232 ) ? { 1'b0, amd } : { 1'b1, pmd };
    end else if ( step < 8'd242 ) begin
        s_reg   = 8'h08;
        s_ram   = 0;
        s_fixed = { 1'b0, keyon[ { s_ch[2:0], 2'b00 } +: 4 ], s_ch[2:0] };
    end else begin
        s_reg       = cur_addr;
        s_addr_only = 1;
    end
    s_valid = ( step < 8'd234 ) ? valid[s_reg] : 1'b1;
end

typedef enum logic [3:0] { P_IDLE, P_PREP, P_READ, P_DATA, P_AW, P_AW_GAP, P_DW, P_DW_WAIT } pstate_t;
pstate_t   ps = P_IDLE;
reg [10:0] cnt;
reg  [7:0] data_r;

assign busy = ( ps != P_IDLE );

always @(posedge clk) begin
    case ( ps )
        P_IDLE: begin
            ym_wr <= 0;
            if ( replay ) begin
                step <= 0;
                ps   <= P_PREP;
            end
        end
        P_PREP: begin
            rp_addr <= s_reg;
            if ( step > 8'd242 )  ps <= P_IDLE;
            else if ( !s_valid )  step <= step + 1'd1;
            else                  ps <= P_READ;
        end
        P_READ: ps <= P_DATA;
        P_DATA: begin
            data_r <= s_ram ? rd_q : s_fixed;
            ym_a0  <= 0;
            ym_din <= s_reg;
            ym_wr  <= 1;
            cnt    <= 0;
            ps     <= P_AW;
        end
        P_AW: begin
            cnt <= cnt + 1'd1;
            if ( cnt == 11'd47 ) begin
                ym_wr <= 0;
                cnt   <= 0;
                ps    <= P_AW_GAP;
            end
        end
        P_AW_GAP: begin
            cnt <= cnt + 1'd1;
            if ( cnt == 11'd47 ) begin
                if ( s_addr_only ) begin
                    step <= step + 1'd1;
                    ps   <= P_PREP;
                end else begin
                    ym_a0  <= 1;
                    ym_din <= data_r;
                    ym_wr  <= 1;
                    cnt    <= 0;
                    ps     <= P_DW;
                end
            end
        end
        P_DW: begin
            cnt <= cnt + 1'd1;
            if ( cnt == 11'd47 ) begin
                ym_wr <= 0;
                cnt   <= 0;
                ps    <= P_DW_WAIT;
            end
        end
        P_DW_WAIT: begin
            if ( cnt != 11'h7ff ) cnt <= cnt + 1'd1;
            if ( cnt >= 11'd1535 && !ym_busy ) begin
                step <= step + 1'd1;
                ps   <= P_PREP;
            end
        end
        default: ps <= P_IDLE;
    endcase
end

endmodule


// Buffers screen_rotate's single-beat DDRAM writes and replays them as a ddr_if master that honours busy.
module megasys1_rotate_ddr (
    input            clk,
    input     [28:0] addr,
    input     [63:0] din,
    input      [7:0] be,
    input            we,
    ddr_if.to_host   ddr
);

reg [68:0] fifo [0:1023];
reg  [9:0] wp = 0;
reg  [9:0] rp = 0;
reg [68:0] q;
reg  [1:0] st = 0;

wire fifo_we = we && ( wp + 1'd1 ) != rp;

assign ddr.read     = 0;
assign ddr.burstcnt = 8'd1;

always @(posedge clk) begin
    if ( fifo_we ) fifo[wp] <= { addr, be, din[31:0] };
    q <= fifo[rp];
end

always @(posedge clk) begin
    if ( fifo_we ) wp <= wp + 1'd1;

    case ( st )
        2'd0: if ( rp != wp ) begin
                  ddr.acquire <= 1;
                  st          <= 2'd1;
              end else begin
                  ddr.acquire <= 0;
              end
        2'd1: st <= 2'd2;
        2'd2: begin
                  ddr.addr       <= { q[68:40], 3'b000 };
                  ddr.byteenable <= q[39:32];
                  ddr.wdata      <= { q[31:0], q[31:0] };
                  ddr.write      <= 1;
                  st             <= 2'd3;
              end
        2'd3: if ( !ddr.busy ) begin
                  ddr.write <= 0;
                  rp        <= rp + 1'd1;
                  st        <= 2'd0;
              end
    endcase
end

endmodule
