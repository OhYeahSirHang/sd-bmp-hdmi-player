`timescale 1ns/1ps
// 25MHz SPI 婵☆垪鈧磭纭€濞戞挸顑囧�?sd_rd CMD18 濠㈣埖鑹惧锛勬嫚缂佹銈撮悹鍥ㄦ穿�? 闁秆勵殣�?
module tb_sd_multi;
reg clk=0, rst_n=0;
reg start=0;
reg [31:0] sec=0;
reg multi=1;
reg [15:0] blk_cnt=4;
wire cs, mosi, busy, done, vld;
wire [7:0] dout;

reg sd_clk_r=0;
wire sd_tx_en = sd_clk_r;
wire sd_rx_en = ~sd_clk_r;
reg miso=1;

always #10 clk=~clk;
always @(posedge clk) sd_clk_r <= ~sd_clk_r;

sd_rd dut(
    .clk(clk), .rst_n(rst_n),
    .sd_cs_n(cs), .sd_miso(miso), .sd_mosi(mosi),
    .sd_rd_start(start), .sd_rd_sec_addr(sec),
    .sd_rd_multi(multi), .sd_rd_blk_cnt(blk_cnt),
    .sd_tx_en(sd_tx_en), .sd_rx_en(sd_rx_en),
    .sd_rd_data_valid(vld), .sd_rd_data(dout),
    .sd_rd_busy(busy), .sd_rd_done(done)
);


integer nbytes=0, ndone=0;

reg [2:0] st_d=0;
always @(posedge clk) begin
    if(dut.state !== st_d) begin
        st_d <= dut.state;
        $display("[%0t] state %0d -> %0d cs=%b tx=%b rx=%b miso=%b", $time, st_d, dut.state, cs, sd_tx_en, sd_rx_en, miso);
    end
end

always @(posedge clk) begin
    if(sd_rx_en && !cs && ($time < 4000))
        $display("[%0t] rx miso=%b ackf=%b cnt=%0d data=%02x st=%0d", $time, miso, dut.ack_flag, dut.ack_bit_cnt, dut.ack_data, dut.state);
end

always @(posedge clk) begin

    if(vld) begin
        nbytes = nbytes + 1;
        if((nbytes % 512) == 0) $display("block %0d done at %0t", nbytes/512, $time);
    end
    if(done) begin
        ndone = ndone + 1;
        $display("DONE at %0t, bytes=%0d", $time, nbytes);
    end
end

// ---------------- card model ----------------
localparam C_IDLE=0, C_CMD=1, C_RESP=2, C_TOKEN=3, C_DATA=4, C_CRC=5, C_STOP=6, C_STOP_RESP=7;
integer cst=C_IDLE;
integer bitcnt=0;
integer blocks=0;
reg [7:0] sh;
reg [7:0] resp;
integer byteidx=0;
reg [7:0] databyte;

task load_byte(input [7:0] b);
    begin sh=b; bitcnt=0; end
endtask

always @(posedge clk) begin
    if(cs) begin
        cst <= C_IDLE;
        bitcnt <= 0;
        blocks <= 0;
        byteidx <= 0;
        miso <= 1;
    end
    else begin
        // MOSI 闁哄洤鐡ㄩ弻濠囧捶閵娿倗鐟撻梻鍕У�?(sd_tx_en=1)闁挎稑顒營SO 濞戞梻鍠庡﹢顏呮交濞嗘挸娅￠柡鍥х摠閺?
        if(sd_tx_en) begin
            case(cst)
            C_IDLE: begin
                cst <= C_CMD; bitcnt <= 0; miso <= 1;
            end
            C_CMD: begin
                if(bitcnt == 47) begin
                    cst <= C_RESP; bitcnt <= 0; resp <= 8'h00;
                    miso <= 1;
                end
                else bitcnt <= bitcnt + 1;
            end
            C_RESP: begin
                miso <= resp[7];
                resp <= {resp[6:0], 1'b0};
                if(bitcnt == 7) begin
                    cst <= C_TOKEN; bitcnt <= 0;
                    load_byte(8'hFE);
                end
                else bitcnt <= bitcnt + 1;
            end
            C_TOKEN: begin
                miso <= sh[7];
                sh <= {sh[6:0], 1'b0};
                if(bitcnt == 7) begin
                    cst <= C_DATA; bitcnt <= 0; byteidx <= 0;
                    load_byte(8'hA5 ^ byteidx[7:0]);
                end
                else bitcnt <= bitcnt + 1;
            end
            C_DATA: begin
                miso <= sh[7];
                sh <= {sh[6:0], 1'b0};
                if(bitcnt == 7) begin
                    bitcnt <= 0;
                    byteidx <= byteidx + 1;
                    if(byteidx == 511) begin
                        cst <= C_CRC; byteidx <= 0;
                        load_byte(8'h00);
                    end
                    else load_byte(8'hA5 ^ byteidx[7:0]);
                end
                else bitcnt <= bitcnt + 1;
            end
            C_CRC: begin
                miso <= sh[7];
                sh <= {sh[6:0], 1'b0};
                if(bitcnt == 7) begin
                    bitcnt <= 0;
                    byteidx <= byteidx + 1;
                    if(byteidx == 1) begin
                        blocks <= blocks + 1;
                        if(blocks + 1 == blk_cnt) begin
                            cst <= C_STOP; bitcnt <= 0; miso <= 1;
                        end
                        else begin
                            cst <= C_TOKEN; bitcnt <= 0;
                            load_byte(8'hFE);
                        end
                    end
                    else load_byte(8'h00);
                end
                else bitcnt <= bitcnt + 1;
            end
            C_STOP: begin
                // �?CMD12 �?48 bit
                if(bitcnt == 47) begin
                    cst <= C_STOP_RESP; bitcnt <= 0; resp <= 8'h00; miso <= 1;
                end
                else bitcnt <= bitcnt + 1;
            end
            C_STOP_RESP: begin
                miso <= resp[7];
                resp <= {resp[6:0], 1'b0};
                if(bitcnt == 7) begin
                    cst <= C_IDLE; bitcnt <= 0; miso <= 1;
                end
                else bitcnt <= bitcnt + 1;
            end
            endcase
        end
    end
end

initial begin
    #100 rst_n=1;
    #200 start=1; sec=100;
    #40 start=0;
    #3_000_000;
    $display("RESULT ndone=%0d bytes=%0d state=%0d", ndone, nbytes, dut.state);
    if(ndone==1 && nbytes==2048 && dut.state==0) $display("PASS");
    else $display("FAIL");
    $finish;
end
endmodule
