`timescale 1ns/1ps
// --------------------------------------------------------------------
// sd_rd.v -- SPI 模式 SD 卡读控制器
//
// 2026-10-28 修改:
//   - 支持 CMD18 多块连续读 (sd_rd_multi=1, sd_rd_blk_cnt 指定块数),
//     读完后自动发 CMD12 停止; 单块模式仍走 CMD17, 供 BMP/探测使用。
//   - 位级逻辑增加 sd_tx_en / sd_rx_en 时钟使能:
//       * 单块模式: 50MHz SPI, 两个使能每个 clk 都为 1 (与原逻辑一致);
//       * 多块模式: 25MHz SPI, tx_en 在 sd_clk 下降沿、rx_en 在上升沿,
//         使 SD 读取速率 (3.125MB/s) 低于 1080p 生成消耗速率,
//         从而不需要大 FIFO, 也不会覆盖只有 4 行的行缓冲。
//   - wait_cnt 在 IDLE 清零: 原实现第一个扇区后 wait_cnt 从 15 继续数到 63,
//     多等约 48 个时钟/扇区; 这里顺手修正。
// --------------------------------------------------------------------
module sd_rd(
       input        clk             ,
       input        rst_n           ,

       // SD 卡接口
       output reg   sd_cs_n          ,
       input        sd_miso          ,
       output reg   sd_mosi          ,

       // 用户接口
       input             sd_rd_start         ,
       input      [31:0] sd_rd_sec_addr      ,
       input             sd_rd_multi         , // 1=CMD18 多块, 0=CMD17 单块
       input      [15:0] sd_rd_blk_cnt       , // 多块模式本次要读的 512B 块数
       input             sd_tx_en            , // MOSI 更新使能 (25M 模式下为下降沿)
       input             sd_rx_en            , // MISO 采样使能 (25M 模式下为上升沿)

       output reg        sd_rd_data_valid    ,
       output reg [7:0]  sd_rd_data          ,
       output            sd_rd_busy          ,
       output reg        sd_rd_done
    );

localparam [2:0] IDLE    = 3'd0;
localparam [2:0] WR_CMD  = 3'd1;
localparam [2:0] RD_DATA = 3'd2;
localparam [2:0] WR_STOP = 3'd3;
localparam [2:0] RD_DONE = 3'd4;

reg [2:0]  state;

// ---- 命令/应答接收 ----
reg        ack_done;
reg        ack_flag;
reg [5:0]  ack_bit_cnt;
reg [7:0]  ack_data;

// ---- 数据接收 ----
reg        rx_data_done;
reg        rx_data_flag;
reg [5:0]  rx_data_bit_cnt;
reg [9:0]  rx_data_cnt;
reg [7:0]  rx_data;

// ---- 命令发送/收尾 ----
reg [5:0]  cmd_bit_cnt;
reg [5:0]  wait_cnt;
reg [31:0] r_sd_rd_sec_addr;
reg        r_multi;
reg [15:0] blk_left;

wire [47:0] cmd17 = {8'h51, r_sd_rd_sec_addr, 8'hFF}; // CMD17 READ_SINGLE_BLOCK
wire [47:0] cmd18 = {8'h52, r_sd_rd_sec_addr, 8'hFF}; // CMD18 READ_MULTIPLE_BLOCK
wire [47:0] cmd12 = {8'h4C, 32'd0,             8'hFF}; // CMD12 STOP_TRANSMISSION
wire [47:0] cmd_word = (state == WR_STOP) ? cmd12 :
                       (r_multi ? cmd18 : cmd17);

// --------------------------------------------------------------------
// 启动时锁存本次传输参数
// --------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r_sd_rd_sec_addr <= 32'd0;
        r_multi          <= 1'b0;
    end
    else if(sd_rd_start && (state == IDLE)) begin
        r_sd_rd_sec_addr <= sd_rd_sec_addr;
        r_multi          <= sd_rd_multi;
    end
end

// --------------------------------------------------------------------
// 命令应答 (R1) 接收: 等待起始 0, 再收 8 bit
// --------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        ack_done    <= 1'b0;
        ack_flag    <= 1'b0;
        ack_bit_cnt <= 6'd0;
        ack_data    <= 8'd0;
    end
    else begin
        ack_done <= 1'b0;
        if(sd_rx_en) begin
            if((state == WR_CMD) || (state == WR_STOP)) begin
                if(!ack_flag) begin
                    if(sd_miso == 1'b0) begin
                        ack_flag    <= 1'b1;
                        ack_bit_cnt <= 6'd1;   // 这个 0 就是 R1 的 bit7(start)
                        ack_data    <= 8'h00;
                    end
                end
                else begin
                    ack_data <= {ack_data[6:0], sd_miso};
                    if(ack_bit_cnt == 6'd7) begin
                        ack_flag <= 1'b0;
                        ack_done <= 1'b1;
                    end
                    else begin
                        ack_bit_cnt <= ack_bit_cnt + 1'b1;
                    end
                end
            end
        end
    end
end

// --------------------------------------------------------------------
// 512B 数据 + 2B CRC 接收; 多块模式自动接下一块的起始 token
// --------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rx_data_done    <= 1'b0;
        rx_data_flag    <= 1'b0;
        rx_data_bit_cnt <= 6'd0;
        rx_data_cnt     <= 10'd0;
        rx_data         <= 8'd0;
        sd_rd_data_valid <= 1'b0;
        sd_rd_data       <= 8'd0;
    end
    else begin
        sd_rd_data_valid <= 1'b0;
        rx_data_done     <= 1'b0;

        if(sd_rx_en && (state == RD_DATA)) begin
            if(!rx_data_flag) begin
                // 数据起始 token 0xFE 的最后一位是 0, 从这里开始
                if(sd_miso == 1'b0) begin
                    rx_data_flag    <= 1'b1;
                    rx_data_bit_cnt <= 6'd0;
                end
            end
            else begin
                rx_data <= {rx_data[6:0], sd_miso};
                if(rx_data_bit_cnt == 6'd7) begin
                    rx_data_bit_cnt <= 6'd0;

                    // 0..511 为有效数据, 512/513 为 CRC
                    if(rx_data_cnt <= 10'd511) begin
                        sd_rd_data       <= {rx_data[6:0], sd_miso};
                        sd_rd_data_valid <= 1'b1;
                    end

                    if(rx_data_cnt == 10'd513) begin
                        rx_data_done <= 1'b1;
                        rx_data_cnt  <= 10'd0;
                        rx_data_flag <= 1'b0;
                    end
                    else begin
                        rx_data_cnt <= rx_data_cnt + 1'b1;
                    end
                end
                else begin
                    rx_data_bit_cnt <= rx_data_bit_cnt + 1'b1;
                end
            end
        end
    end
end

// --------------------------------------------------------------------
// 主状态机
// --------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= IDLE;
        blk_left <= 16'd1;
    end
    else begin
        case(state)
        IDLE: begin
            if(sd_rd_start) begin
                blk_left <= (sd_rd_blk_cnt == 16'd0) ? 16'd1 : sd_rd_blk_cnt;
                state    <= WR_CMD;
            end
        end
        WR_CMD: begin
            if(ack_done) begin
                if(ack_data == 8'h00)
                    state <= RD_DATA;
                else
                    state <= IDLE;
            end
        end
        RD_DATA: begin
            if(rx_data_done) begin
                if(r_multi) begin
                    if(blk_left > 16'd1) begin
                        blk_left <= blk_left - 1'b1;
                        // 保持在 RD_DATA, 等下一块的 0xFE token
                    end
                    else begin
                        state <= WR_STOP; // 最后一块, 发 CMD12
                    end
                end
                else begin
                    state <= RD_DONE;
                end
            end
        end
        WR_STOP: begin
            if(ack_done)
                state <= RD_DONE;
        end
        RD_DONE: begin
            if(wait_cnt == 6'd15)
                state <= IDLE;
        end
        default: state <= IDLE;
        endcase
    end
end

// --------------------------------------------------------------------
// 命令发送 / CS / 收尾时序
// --------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sd_cs_n    <= 1'b1;
        sd_mosi    <= 1'b1;
        cmd_bit_cnt<= 6'd0;
        wait_cnt   <= 6'd0;
        sd_rd_done <= 1'b0;
    end
    else begin
        case(state)
        IDLE: begin
            sd_cs_n    <= 1'b1;
            sd_mosi    <= 1'b1;
            cmd_bit_cnt<= 6'd0;
            wait_cnt   <= 6'd0;       // 关键: 每个事务结束都清零
            sd_rd_done <= 1'b0;
        end
        WR_CMD, WR_STOP: begin
            sd_cs_n <= 1'b0;
            if(cmd_bit_cnt <= 6'd47) begin
                if(sd_tx_en) begin
                    sd_mosi     <= cmd_word[47-cmd_bit_cnt];
                    cmd_bit_cnt <= cmd_bit_cnt + 1'b1;
                end
            end
            else begin
                sd_mosi <= 1'b1;
                if(ack_done)
                    cmd_bit_cnt <= 6'd0;
            end
        end
        RD_DATA: begin
            sd_cs_n <= 1'b0;
            sd_mosi <= 1'b1;
            cmd_bit_cnt <= 6'd0;      // 为后面的 CMD12 准备
        end
        RD_DONE: begin
            wait_cnt <= wait_cnt + 1'b1;
            if(wait_cnt == 6'd7)
                sd_cs_n <= 1'b1;
            if(wait_cnt == 6'd15)
                sd_rd_done <= 1'b1;
        end
        default: begin
            sd_cs_n <= 1'b1;
            sd_mosi <= 1'b1;
            cmd_bit_cnt <= 6'd0;
            wait_cnt <= 6'd0;
        end
        endcase
    end
end

assign sd_rd_busy = (state != IDLE);

endmodule
