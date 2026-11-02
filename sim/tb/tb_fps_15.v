`timescale 1ns/1ps
// vid_player 15fps verification: 60Hz vsync, CMD18 frame read modeled at 25MHz SPI
module tb_fps_15;
localparam CLK_HALF = 10;
reg clk, rst_n;
reg init_done = 0;
reg vsync = 0;
wire wr_buf_sel, disp_buf_sel, frame_ready, find_led;
wire sd_rd_start;
wire [31:0] sd_rd_sec_addr;
wire sd_rd_multi;
wire [15:0] sd_rd_blk_cnt;
reg  sd_rd_data_valid = 0;
reg  [7:0] sd_rd_data = 0;
reg  sd_rd_done = 0;
wire [15:0] vid_px;
wire vid_px_vld;
wire probe_done, is_video;
wire vid_next_ack;
wire [3:0] ft, fo;

vid_player dut(
    .clk(clk), .rst_n(rst_n), .init_done(init_done),
    .vsync(vsync), .swap_allow(1'b1), .vid_next(1'b0),
    .vid_next_ack(vid_next_ack),
    .wr_buf_sel(wr_buf_sel), .disp_buf_sel(disp_buf_sel),
    .frame_ready(frame_ready), .find_led(find_led),
    .sd_rd_start(sd_rd_start), .sd_rd_sec_addr(sd_rd_sec_addr),
    .sd_rd_multi(sd_rd_multi), .sd_rd_blk_cnt(sd_rd_blk_cnt),
    .sd_rd_data_valid(sd_rd_data_valid), .sd_rd_data(sd_rd_data),
    .sd_rd_done(sd_rd_done), .sd_busy(1'b0),
    .vid_px(vid_px), .vid_px_vld(vid_px_vld),
    .probe_done(probe_done), .is_video(is_video),
    .vid_fps_t(ft), .vid_fps_o(fo)
);

always #CLK_HALF clk = ~clk;

// 1080p60 vsync, ~74us high every 16.667ms
initial begin
    vsync = 0;
    #1_000_000;
    forever begin
        #(16_667_000 - 74_000) vsync = 1;
        #74_000 vsync = 0;
    end
end

// ---- fake SD: single block 50MHz (8 clk/B), multi block 25MHz (16 clk/B) ----
reg [31:0] cur_sec;
reg [9:0]  bi;
reg [15:0] blk_left;
reg        busy = 0;
integer    gap;
reg        multi_lat;

function [7:0] sec_byte(input [31:0] sec, input integer off);
    reg [31:0] idx;
    begin
        if(sec == 0) begin
            case(off)
            0: sec_byte=8'h44; 1: sec_byte=8'h56; 2: sec_byte=8'h31; 3: sec_byte=8'h00;
            4: sec_byte=8'd64; 5: sec_byte=8'd1;
            6: sec_byte=8'd240; 7: sec_byte=8'd0;
            8: sec_byte=8'd15; 9: sec_byte=8'd0;
            10: sec_byte=8'd0; 11: sec_byte=8'd88; 12: sec_byte=8'd2; 13: sec_byte=8'd0;
            14: sec_byte=8'd60; 15: sec_byte=8'd0; 16: sec_byte=8'd0; 17: sec_byte=8'd0;
            default: sec_byte=8'd0;
            endcase
        end
        else begin
            idx = (sec-1)*512 + off;
            sec_byte = idx[7:0] ^ idx[15:8];
        end
    end
endfunction

always @(posedge clk) begin
    sd_rd_data_valid <= 0;
    sd_rd_done <= 0;
    if(!busy) begin
        if(sd_rd_start) begin
            busy <= 1;
            cur_sec <= sd_rd_sec_addr;
            multi_lat <= sd_rd_multi;
            blk_left <= sd_rd_multi ? sd_rd_blk_cnt : 16'd1;
            bi <= 0;
            gap <= sd_rd_multi ? 15 : 7;
        end
    end
    else begin
        if(gap > 0) gap <= gap - 1;
        else if(bi < 512) begin
            sd_rd_data <= sec_byte(cur_sec, bi);
            sd_rd_data_valid <= 1;
            bi <= bi + 1;
            gap <= 15;                      // 25MHz: 16 clk/byte
        end
        else begin
            if(multi_lat && (blk_left > 1)) begin
                blk_left <= blk_left - 1;
                cur_sec  <= cur_sec + 1;
                bi <= 0;
                gap <= 15;
            end
            else begin
                sd_rd_done <= 1;
                busy <= 0;
            end
        end
    end
end

integer nswap = 0;
time t_last = 0, t_now;
always @(posedge clk) begin
    if(dut.swap_done) begin
        nswap = nswap + 1;
        t_now = $time;
        $display("SWAP %0d at %0t ns, interval %0t ns", nswap, t_now, t_now - t_last);
        t_last = t_now;
    end
end

initial begin
    clk = 0; rst_n = 0;
    #200 rst_n = 1;
    #200 init_done = 1;
    #1_200_000_000;
    $display("RESULT swaps=%0d fps=%0d%0d", nswap, ft, fo);
    if((nswap >= 16) && (nswap <= 20)) $display("PACING_OK");
    $finish;
end
endmodule
