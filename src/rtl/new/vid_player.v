`timescale 1ns/1ps
// --------------------------------------------------------------------
// vid_player.v -- 小分辨率视频播放（DV1 容器 / RGB565 / 320x240@15fps）
//   出: 1920x1080 RGB565 像素流(3x 整数放大 + 黑边居中)，直接写进
//       与图片相同的 DDR3 帧缓冲，显示链/15 种模式/OSD 全部不用改。
//
// DV1 容器（从扇区 0 开始）:
//   0 'D' 1 'V' 2 '1' 3 00
//   4-5 W(LE)  6-7 H(LE)  8 fps  9 fmt(0=RGB565)
//   10-13 frame_bytes(LE, 512 对齐)  14-17 frame_count(LE)
//   帧数据从扇区 1 起, 每帧 FRAME_SECS 个扇区, 像素高字节在前
//
// 流控: 生成器先出 180 行黑边 → 等第一行数据 → 每源行出 3 行 →
//       180 行黑边 → VSYNC 换帧; 读侧等生成器进入"等行"状态后才开始读,
//       两块行缓冲乒乓, 保证不会写坏正在用的行。
// --------------------------------------------------------------------
module vid_player #(
    parameter [31:0] STOP_SECTOR = 32'h0003_2000
)(
    input               clk          , // 50MHz
    input               rst_n        ,
    input               init_done    ,
    input               vsync        , // 148.5M 域
    input               swap_allow   , // 视频模式不用
    input               vid_next     , // 下一段视频脉冲(菜单行1)
    output reg          wr_buf_sel   ,
    output reg          disp_buf_sel ,
    output reg          frame_ready  ,
    output reg          find_led     ,
    output reg          sd_rd_start  ,
    output reg [31:0]   sd_rd_sec_addr,
    output reg          sd_rd_multi   , // 1=整帧 CMD18 多块读
    output reg [15:0]   sd_rd_blk_cnt , // 本次多块读的 512B 块数
    output reg          vid_next_ack , // 1: 本次 vid_next 已被接受(用于帧同步)
    input               sd_rd_data_valid,
    input      [7:0]    sd_rd_data   ,
    input               sd_rd_done   ,
    input               sd_busy      ,
    output     [15:0]   vid_px       ,
    output reg          vid_px_vld   ,
    output reg          probe_done   ,
    output reg          is_video     ,
    output reg [3:0]    vid_fps_t    , // 实测帧率(十位)
    output reg [3:0]    vid_fps_o      // 实测帧率(个位)
);
localparam [8:0]  VID_W      = 9'd320;
localparam [8:0]  VID_H      = 9'd240;
localparam [9:0]  FRAME_SECS = 10'd300;
localparam [10:0] X0         = 11'd480;
localparam [10:0] Y0         = 11'd180;
localparam [10:0] DISP_W     = 11'd1920;

// ---- VSYNC 同步 ----
reg vs_d1, vs_d2, vs_d3;
wire vsync_rise = vs_d2 & ~vs_d3;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin vs_d1<=1'b0; vs_d2<=1'b0; vs_d3<=1'b0; end
    else begin vs_d1<=vsync; vs_d2<=vs_d1; vs_d3<=vs_d2; end
end

// ---- 行缓冲(乒乓) ----
(* ram_style="block" *) reg [15:0] lbuf0 [0:511];
(* ram_style="block" *) reg [15:0] lbuf1 [0:511];
(* ram_style="block" *) reg [15:0] lbuf2 [0:511];
(* ram_style="block" *) reg [15:0] lbuf3 [0:511];
reg [1:0]  lb_wr, lb_rd;
reg [3:0]  row_ready;
reg [8:0]  col;
reg [7:0]  row_wr;
reg [15:0] wr_pix;
reg        wr_do;
// 写口独立块(无复位, 才能推断 BRAM): 4 块乒乓
always @(posedge clk) begin
    if(wr_do) begin
        case(lb_wr)
        2'd0: lbuf0[col] <= wr_pix;
        2'd1: lbuf1[col] <= wr_pix;
        2'd2: lbuf2[col] <= wr_pix;
        default: lbuf3[col] <= wr_pix;
        endcase
    end
end
reg [10:0] raddr;
reg [15:0] lbuf_q;
// 读口独立块(便于推断 BRAM)
always @(posedge clk) begin
    case(lb_rd)
    2'd0: lbuf_q <= lbuf0[raddr];
    2'd1: lbuf_q <= lbuf1[raddr];
    2'd2: lbuf_q <= lbuf2[raddr];
    default: lbuf_q <= lbuf3[raddr];
    endcase
end

// ---- 探测 ----
reg [3:0]  pstate;
reg [5:0]  hdr_cnt;
reg [7:0]  hdr0,hdr1,hdr2,hdr3,hdr4,hdr5,hdr6,hdr7,hdr8,hdr9;
reg [7:0]  hdr10,hdr11,hdr12,hdr13,hdr14,hdr15,hdr16,hdr17;
reg [31:0] frame_bytes, frame_count;
wire [15:0] vid_w_d = {hdr5,hdr4};
wire [15:0] vid_h_d = {hdr7,hdr6};
wire        hdr_ok  = (hdr0==8'h44)&&(hdr1==8'h56)&&(hdr2==8'h31)&&(hdr3==8'h00)
                   && (vid_w_d==16'd320) && (vid_h_d==16'd240) && (hdr9==8'd0);

// ---- 读帧 ----
reg [3:0]  rstate;
reg [15:0] frame_idx;
reg [31:0] frame_base;      // 本帧首扇区号
reg [31:0] scan_sec;        // 扫描中的扇区
reg [31:0] cur_hdr;         // 当前视频头部扇区
reg        seek;            // 正在做下一段跳转
reg        wrapped;         // 已回绕到卡首扫描
reg [31:0] max_end;         // 已发现视频的最大末尾扇区
reg [26:0] sec_cnt;         // 1 秒计时(50M)
reg [7:0]  fps_cnt;         // 窗口内帧数
reg        fps_started;     // 第一帧后才开始 1 秒窗口
reg [1:0]  pace;            // 15fps 节流: 4 个 VSYNC 一帧
wire [31:0] skip_secs = (frame_count << 8) + (frame_count << 5) + (frame_count << 3) + (frame_count << 2); // x300
reg [31:0] base0;           // 第一帧首扇区(循环回绕用)
reg [19:0] led_cnt;         // 扫描指示闪烁
localparam [31:0] SCAN_MAX = 32'h0002_0000;   // 扫描上限 64MB
reg [7:0]  pix_hi;
reg        byte_hi;
reg        gen_wait_seen;   // 生成器已进入等行状态

localparam S_PROBE_REQ=4'd0, S_PROBE_WAIT=4'd1, S_PROBE_CHK=4'd2,
           S_IDLE     =4'd3, S_FRM_REQ   =4'd4, S_FRM_WAIT =4'd5,
           S_FRM_END  =4'd6;

// ---- 生成器 ----
localparam G_IDLE=4'd0, G_TOPB=4'd1, G_WAIT=4'd2, G_LEFT=4'd3,
           G_VID =4'd4, G_RIGHT=4'd5, G_BOTB=4'd6, G_SWAP=4'd7;
reg [3:0]  gstate;
reg [10:0] px, gy;
reg [8:0]  gen_row;
reg [1:0]  sub;
reg [1:0]  sx3;             // 源像素 3 次重复计数
reg        swap_done;
reg [15:0] vpx;
assign vid_px = vpx;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pstate<=S_PROBE_REQ; hdr_cnt<=6'd0; probe_done<=1'b0; is_video<=1'b0;
        hdr0<=0;hdr1<=0;hdr2<=0;hdr3<=0;hdr4<=0;hdr5<=0;hdr6<=0;hdr7<=0;hdr8<=0;hdr9<=0;
        hdr10<=0;hdr11<=0;hdr12<=0;hdr13<=0;hdr14<=0;hdr15<=0;hdr16<=0;hdr17<=0;
        frame_bytes<=0; frame_count<=0;
        sd_rd_start<=0; sd_rd_sec_addr<=0; sd_rd_multi<=1'b0; sd_rd_blk_cnt<=16'd1; vid_next_ack<=1'b0; find_led<=0;
        rstate<=S_IDLE; frame_idx<=16'd0; frame_base<=32'd1; scan_sec<=32'd0; base0<=32'd1; cur_hdr<=32'd0; seek<=1'b0; wrapped<=1'b0; max_end<=32'd0; sec_cnt<=27'd0; fps_cnt<=8'd0; fps_started<=1'b0; pace<=2'd0; vid_fps_t<=4'd0; vid_fps_o<=4'd0; pix_hi<=0; byte_hi<=1;
        lb_wr<=0; lb_rd<=0; row_ready<=4'd0; col<=0; row_wr<=0; raddr<=0; wr_pix<=0; wr_do<=0;
        gen_wait_seen<=0;
        wr_buf_sel<=1'b1; disp_buf_sel<=1'b0; frame_ready<=0;
        gstate<=G_IDLE; px<=0; gy<=0; gen_row<=0; sub<=0; sx3<=0; swap_done<=0; vpx<=0; vid_px_vld<=0;
    end
    else begin
        swap_done  <= 1'b0;
        vid_px_vld <= 1'b0;
        vid_next_ack <= 1'b0;
        led_cnt    <= led_cnt + 20'd1;

        // ---------- 15fps 节流: 每帧至少等 4 个 VSYNC (66.67ms) ----------
        if(swap_done)
            pace <= 2'd3;
        else if(vsync_rise && (pace != 2'd0))
            pace <= pace - 1'b1;

        // ---------- 实测帧率(第一帧后开始 1 秒窗口) ----------
        if(!fps_started) begin
            if(swap_done) begin
                fps_started <= 1'b1;
                sec_cnt     <= 27'd0;
                fps_cnt     <= 8'd1;
            end
        end
        else if(sec_cnt == 27'd49_999_999) begin
            sec_cnt   <= 27'd0;
            fps_cnt   <= 8'd0;
            vid_fps_t <= (fps_cnt / 8'd10);
            vid_fps_o <= (fps_cnt % 8'd10);
        end
        else begin
            sec_cnt <= sec_cnt + 27'd1;
            if(swap_done) fps_cnt <= fps_cnt + 8'd1;
        end

        // ---------- 菜单行1: 下一段视频 ----------
        // 只在 SD 空闲、且不处于读帧/等换帧时接受, 避免 CMD18 读帧途中
        // 发探测命令被 sd_rd 忽略而卡死。
        if(vid_next && is_video && !seek && !sd_busy &&
           (rstate != S_FRM_WAIT) && (rstate != S_FRM_END)) begin
            seek          <= 1'b1;
            vid_next_ack  <= 1'b1;   // 只有真正接受时才让顶层 frame_sync
            if((cur_hdr + 32'd1 + skip_secs) >= max_end)
                scan_sec  <= 32'd0;                      // 当前已是最后一段 -> 直接回卡首
            else
                scan_sec  <= cur_hdr + 32'd1 + skip_secs; // 从本段末尾往后再扫
            wrapped       <= 1'b0;
            pstate        <= S_PROBE_REQ;
            rstate        <= S_PROBE_REQ;
            sd_rd_multi   <= 1'b0;
            sd_rd_blk_cnt <= 16'd1;
            frame_idx     <= 16'd0;
            row_wr        <= 8'd0;
            col           <= 9'd0;
            gen_wait_seen <= 1'b0;
            row_ready     <= 4'd0;
            lb_wr         <= 1'b0;
            lb_rd         <= 1'b0;
            gstate        <= G_IDLE;
        end
        wr_do      <= 1'b0;

        // ================= 探测 =================
        case(pstate)
        S_PROBE_REQ: if(init_done && !sd_busy) begin
            // 逐扇区扫描, 找 'DV1\0' (卡上可以同时有 BMP, 视频放在哪儿都行)
            sd_rd_sec_addr <= scan_sec;
            sd_rd_multi    <= 1'b0;      // 探测始终单块 CMD17
            sd_rd_blk_cnt  <= 16'd1;
            sd_rd_start    <= 1'b1;
            hdr_cnt        <= 6'd0;
            pstate         <= S_PROBE_WAIT;
        end
        S_PROBE_WAIT: begin
            sd_rd_start <= 1'b0;
            if(sd_rd_data_valid) begin
                case(hdr_cnt)
                6'd0: hdr0<=sd_rd_data;  6'd1: hdr1<=sd_rd_data;
                6'd2: hdr2<=sd_rd_data;  6'd3: hdr3<=sd_rd_data;
                6'd4: hdr4<=sd_rd_data;  6'd5: hdr5<=sd_rd_data;
                6'd6: hdr6<=sd_rd_data;  6'd7: hdr7<=sd_rd_data;
                6'd8: hdr8<=sd_rd_data;  6'd9: hdr9<=sd_rd_data;
                6'd10:hdr10<=sd_rd_data; 6'd11:hdr11<=sd_rd_data;
                6'd12:hdr12<=sd_rd_data; 6'd13:hdr13<=sd_rd_data;
                6'd14:hdr14<=sd_rd_data; 6'd15:hdr15<=sd_rd_data;
                6'd16:hdr16<=sd_rd_data; 6'd17:hdr17<=sd_rd_data;
                default: ;
                endcase
                if(hdr_cnt != 6'h3F) hdr_cnt <= hdr_cnt + 1'b1;
            end
            if(sd_rd_done) pstate <= S_PROBE_CHK;
            if(!probe_done) find_led <= led_cnt[19];   // 扫描中闪烁
        end
        S_PROBE_CHK: begin
            if(hdr_ok) begin
                frame_bytes <= {hdr13,hdr12,hdr11,hdr10};
                frame_count <= {hdr17,hdr16,hdr15,hdr14};
                is_video    <= 1'b1;
                cur_hdr     <= scan_sec;
                if((scan_sec + 32'd1 + skip_secs) > max_end) max_end <= scan_sec + 32'd1 + skip_secs;
                seek        <= 1'b0;
                wrapped     <= 1'b0;
                probe_done  <= 1'b1;
                find_led    <= 1'b1;
                sd_rd_multi <= 1'b0;
                sd_rd_blk_cnt <= 16'd1;
                frame_base  <= scan_sec + 32'd1;   // 帧数据紧跟头部扇区
                base0       <= scan_sec + 32'd1;
                col         <= 9'd0;
                row_wr      <= 8'd0;
                byte_hi     <= 1'b1;
                rstate      <= S_FRM_REQ;
                pstate      <= S_IDLE;
            end
            else if(scan_sec >= SCAN_MAX) begin
                if(!wrapped) begin
                    scan_sec <= 32'd0;      // 扫到末尾没找到 -> 回到卡首再扫
                    wrapped  <= 1'b1;
                    pstate   <= S_PROBE_REQ;
                end
                else begin
                    scan_sec <= cur_hdr;    // 仍没找到 -> 退回当前视频
                    wrapped  <= 1'b0;
                    pstate   <= S_PROBE_REQ;
                end
            end
            else begin
                scan_sec <= scan_sec + 32'd1;
                pstate   <= S_PROBE_REQ;
            end
        end
        S_IDLE: sd_rd_start <= 1'b0;
        default: ;
        endcase

        // ================= 读帧 =================
        if(is_video) begin
            case(rstate)
            S_FRM_REQ: begin
                // 等生成器开始等第一行(顶边黑条已发完), 保证行缓冲够用
                if(gen_wait_seen && ((col != 9'd0) || (!row_ready[lb_wr] && !row_ready[lb_wr + 2'd1]))) begin
                    sd_rd_sec_addr <= frame_base;              // 整帧从首扇区开始
                    sd_rd_multi    <= 1'b1;                    // CMD18 连续读 300 块
                    sd_rd_blk_cnt  <= {6'd0, FRAME_SECS};
                    sd_rd_start    <= 1'b1;
                    byte_hi        <= 1'b1;
                    rstate         <= S_FRM_WAIT;
                end
            end
            S_FRM_WAIT: begin
                sd_rd_start <= 1'b0;
                if(sd_rd_data_valid) begin
                    if(byte_hi) begin
                        pix_hi  <= sd_rd_data;
                        byte_hi <= 1'b0;
                    end
                    else begin
                        byte_hi <= 1'b1;
                        wr_pix  <= {pix_hi, sd_rd_data};
                        wr_do   <= 1'b1;
                        if(col == VID_W-1) begin
                            col              <= 9'd0;
                            row_ready[lb_wr] <= 1'b1;
                            lb_wr            <= lb_wr + 2'd1;
                            if(row_wr != VID_H-1) row_wr <= row_wr + 1'b1;
                        end
                        else col <= col + 1'b1;
                    end
                end
                if(sd_rd_done) begin
                    rstate <= S_FRM_END;                       // 300 块已全部读完
                end
            end
            S_FRM_END: begin
                if(swap_done) begin
                    if(frame_idx + 1'b1 == frame_count) begin
                        frame_base <= base0;
                        frame_idx  <= 16'd0;
                    end
                    else begin
                        frame_base <= frame_base + FRAME_SECS;
                        frame_idx  <= frame_idx + 1'b1;
                    end
                    sd_rd_multi   <= 1'b0;                     // 回到 50MHz，供下一帧探测/读取
                    sd_rd_blk_cnt <= 16'd1;
                    gen_wait_seen <= 1'b0;
                    row_wr        <= 8'd0;
                    col           <= 9'd0;
                    rstate        <= S_FRM_REQ;
                end
            end
            default: ;
            endcase
        end

        // ================= 生成 1080p =================
        case(gstate)
        G_IDLE: if(is_video) begin
            px <= 0; gy <= 0; gen_row <= 0; sub <= 0; sx3 <= 0;
            gstate <= G_TOPB;
        end
        G_TOPB: begin
            vpx <= 16'd0; vid_px_vld <= 1'b1;
            if(px == DISP_W-1) begin
                px <= 0;
                if(gy == Y0-1) begin gy <= 0; gstate <= G_WAIT; end
                else gy <= gy + 1'b1;
            end
            else px <= px + 1'b1;
        end
        G_WAIT: begin
            vid_px_vld  <= 1'b0;
            gen_wait_seen <= 1'b1;
            if(row_ready[lb_rd]) begin
                px <= 0; raddr <= 0; sx3 <= 0;
                gstate <= G_LEFT;
            end
        end
        G_LEFT: begin
            vpx <= 16'd0; vid_px_vld <= 1'b1;
            if(px == X0-1) begin
                raddr  <= 11'd0;          // 预取第 0 个源像素
                px     <= px + 1'b1;
                gstate <= G_VID;
            end
            else px <= px + 1'b1;
        end
        G_VID: begin
            vpx <= lbuf_q; vid_px_vld <= 1'b1;
            if(sx3 == 2'd2) begin
                sx3 <= 2'd0;
                if(raddr < VID_W-1) raddr <= raddr + 1'b1;   // 预取下一个源像素
            end
            else sx3 <= sx3 + 1'b1;
            if(px == X0 + 3*VID_W - 1) begin
                px     <= px + 1'b1;
                gstate <= G_RIGHT;
            end
            else px <= px + 1'b1;
        end
        G_RIGHT: begin
            vpx <= 16'd0; vid_px_vld <= 1'b1;
            if(px == DISP_W-1) begin
                px <= 0;
                if(sub == 2'd2) begin
                    sub <= 2'd0;
                    row_ready[lb_rd] <= 1'b0;
                    lb_rd <= lb_rd + 2'd1;
                    if(gen_row == VID_H-1) begin gen_row <= 0; gstate <= G_BOTB; end
                    else begin gen_row <= gen_row + 1'b1; gstate <= G_WAIT; end
                end
                else begin
                    sub    <= sub + 1'b1;
                    gstate <= G_LEFT;
                end
            end
            else px <= px + 1'b1;
        end
        G_BOTB: begin
            vpx <= 16'd0; vid_px_vld <= 1'b1;
            if(px == DISP_W-1) begin
                px <= 0;
                if(gy == Y0-1) begin gy <= 0; gstate <= G_SWAP; end
                else gy <= gy + 1'b1;
            end
            else px <= px + 1'b1;
        end
        G_SWAP: begin
            vid_px_vld  <= 1'b0;
            frame_ready <= 1'b1;
            if(vsync_rise && (pace == 2'd0)) begin   // 15fps: 4 个 VSYNC 后才允许换帧
                disp_buf_sel <= wr_buf_sel;
                wr_buf_sel   <= ~wr_buf_sel;
                frame_ready  <= 1'b0;
                swap_done    <= 1'b1;
                gstate       <= G_IDLE;
            end
        end
        default: gstate <= G_IDLE;
        endcase
    end
end
endmodule
