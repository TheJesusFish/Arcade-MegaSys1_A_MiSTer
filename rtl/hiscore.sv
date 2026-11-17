// High-score save/restore driven by MAME hiscore.dat entries (main CPU address space, byte granular).
module hiscore #(
    parameter CFG_INDEX = 4,
    parameter NV_INDEX  = 5
) (
    input             clk,
    input             reset,

    input             ioctl_download,
    input             ioctl_upload,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input       [7:0] ioctl_dout,
    input      [15:0] ioctl_index,
    output      [7:0] ioctl_din,
    output reg        upload_req,

    input             vblank,
    input             osd_open,
    input             autosave,
    input             save_now,

    output            enabled,

    output reg        mem_req,
    output reg        mem_we,
    output reg [19:1] mem_addr,
    output reg [15:0] mem_wdata,
    input      [15:0] mem_rdata,
    input             mem_ack
);

typedef enum logic [3:0] {
    S_IDLE, S_WAIT, S_CHECK_START, S_CHECK_END, S_CHECK_NEXT, S_RESTORE, S_RESTORE_WR, S_SAVE, S_SAVE_RD, S_UPLOAD
} state_t;

// entries: { addr[31:0], len[15:0], start[7:0], end[7:0] } as received, 8 bytes each
(* ramstyle = "logic" *) reg [7:0] cfg [0:127];
reg   [4:0] n_entries = 0;
reg   [7:0] nvbuf [0:1023];
reg   [7:0] nv_q;
reg         nv_loaded = 0;
reg   [9:0] ni;
reg   [7:0] rd_byte;
reg   [4:0] ei;
reg  [15:0] bi;
state_t     st = S_IDLE;
reg   [5:0] frames = 0;
reg   [1:0] passes = 0;
reg         restored = 0;
reg         valid_seen = 0;
reg         vbl_d = 0, osd_d = 0, save_d = 0;
reg         ok;
reg         save_pending = 0;

assign enabled = ( n_entries != 0 );

// configuration download
always @(posedge clk) begin
    if (ioctl_download && ioctl_wr && ioctl_index == CFG_INDEX && ioctl_addr < 128) begin
        cfg[ioctl_addr[6:0]] <= ioctl_dout;
        if (ioctl_addr[2:0] == 3'd7) n_entries <= ioctl_addr[7:3] + 1'd1;
    end
end

always @(posedge clk) if (ioctl_download && ioctl_wr && ioctl_index == NV_INDEX) nv_loaded <= 1;

// saved table: one port shared by download, upload (ioctl address) and save/restore (ni)
wire        save_wr = (st == S_SAVE_RD);
wire        nv_io   = (ioctl_download | ioctl_upload) & (ioctl_index == NV_INDEX);
wire  [9:0] nv_addr = nv_io ? ioctl_addr[9:0] : ni;
wire        nv_we   = (nv_io & ioctl_download & ioctl_wr) | save_wr;
wire  [7:0] nv_din  = nv_io ? ioctl_dout : rd_byte;
always @(posedge clk) begin
    if (nv_we) nvbuf[nv_addr] <= nv_din;
    nv_q <= nvbuf[nv_addr];
end
assign ioctl_din = nv_q;

// fields of entry ei
wire  [6:0] eb      = { ei[3:0], 3'b000 };
wire [19:0] e_addr  = { cfg[eb + 1][3:0], cfg[eb + 2], cfg[eb + 3] };
wire [15:0] e_len   = { cfg[eb + 4], cfg[eb + 5] };
wire  [7:0] e_start = cfg[eb + 6];
wire  [7:0] e_end   = cfg[eb + 7];

wire        vbl_rise = vblank & ~vbl_d;
wire [19:0] cur_addr = e_addr + bi;

// byte read helper result
wire  [7:0] mem_byte = cur_addr[0] ? mem_rdata[7:0] : mem_rdata[15:8];

always @(posedge clk) begin
    vbl_d  <= vblank;
    osd_d  <= osd_open;
    save_d <= save_now;
    upload_req <= 0;

    if ((osd_open & ~osd_d & autosave) | (save_now & ~save_d)) save_pending <= 1;

    if (reset) begin
        st <= S_IDLE;
        frames <= 0;
        passes <= 0;
        restored <= 0;
        mem_req <= 0;
    end else begin
        case (st)
        S_IDLE: if (enabled) st <= S_WAIT;

        // wait 30 frames after reset, then check once per frame
        S_WAIT: begin
            if (save_pending && valid_seen) begin
                save_pending <= 0;
                ei <= 0; bi <= 0; ni <= 0;
                st <= S_SAVE;
            end else if (vbl_rise) begin
                if (frames < 30) frames <= frames + 1'd1;
                else if (!restored) begin
                    ei <= 0; ok <= 1;
                    st <= S_CHECK_START;
                end
            end
        end

        S_CHECK_START: begin
            bi <= 0;
            mem_req <= 1; mem_we <= 0; mem_addr <= e_addr[19:1];
            if (mem_req && mem_ack) begin
                mem_req <= 0;
                if (mem_byte != e_start) ok <= 0;
                bi <= e_len - 1'd1;
                st <= S_CHECK_END;
            end
        end

        S_CHECK_END: begin
            mem_req <= 1; mem_we <= 0; mem_addr <= cur_addr[19:1];
            if (mem_req && mem_ack) begin
                mem_req <= 0;
                if (mem_byte != e_end) ok <= 0;
                st <= S_CHECK_NEXT;
            end
        end

        S_CHECK_NEXT: begin
            if (ei + 1'd1 < n_entries) begin
                ei <= ei + 1'd1;
                st <= S_CHECK_START;
            end else begin
                if (ok) begin
                    valid_seen <= 1;
                    if (passes == 1) begin
                        if (nv_loaded) begin
                            ei <= 0; bi <= 0; ni <= 0;
                            st <= S_RESTORE;
                        end else begin
                            restored <= 1;
                            st <= S_WAIT;
                        end
                    end else begin
                        passes <= passes + 1'd1;
                        st <= S_WAIT;
                    end
                end else begin
                    passes <= 0;
                    st <= S_WAIT;
                end
            end
        end

        // restore: read-modify-write each byte from nvbuf
        S_RESTORE: begin
            mem_req <= 1; mem_we <= 0; mem_addr <= cur_addr[19:1];
            if (mem_req && mem_ack) begin
                mem_req <= 0;
                mem_wdata <= cur_addr[0] ? { mem_rdata[15:8], nv_q } : { nv_q, mem_rdata[7:0] };
                st <= S_RESTORE_WR;
            end
        end

        S_RESTORE_WR: begin
            mem_req <= 1; mem_we <= 1;
            if (mem_req && mem_ack) begin
                mem_req <= 0; mem_we <= 0;
                ni <= ni + 1'd1;
                if (bi + 1'd1 < e_len) begin
                    bi <= bi + 1'd1;
                    st <= S_RESTORE;
                end else if (ei + 1'd1 < n_entries) begin
                    ei <= ei + 1'd1; bi <= 0;
                    st <= S_RESTORE;
                end else begin
                    restored <= 1;
                    st <= S_WAIT;
                end
            end
        end

        // save: copy each byte into nvbuf, then request the upload
        S_SAVE: begin
            mem_req <= 1; mem_we <= 0; mem_addr <= cur_addr[19:1];
            if (mem_req && mem_ack) begin
                mem_req <= 0;
                rd_byte <= mem_byte;
                st <= S_SAVE_RD;
            end
        end

        S_SAVE_RD: begin
            ni <= ni + 1'd1;
            if (bi + 1'd1 < e_len) begin
                bi <= bi + 1'd1;
                st <= S_SAVE;
            end else if (ei + 1'd1 < n_entries) begin
                ei <= ei + 1'd1; bi <= 0;
                st <= S_SAVE;
            end else begin
                st <= S_UPLOAD;
            end
        end

        S_UPLOAD: begin
            upload_req <= 1;
            st <= S_WAIT;
        end

        default: st <= S_IDLE;
        endcase
    end
end


endmodule
