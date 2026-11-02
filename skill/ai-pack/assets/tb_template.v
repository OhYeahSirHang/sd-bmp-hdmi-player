`timescale 1ns/1ps
// =====================================================================
// tb_template.v —— 模块级 TB 骨架（Vivado xsim / 通用 Verilog）
// ---------------------------------------------------------------------
// 设计要点（每一条都对应一次真实翻车）：
//   1. DUT 参数用 `parameter` 覆盖而不是改源码：若 DUT 写成 localparam，
//      覆盖会静默失效 —— 先跑一次看 xelab 日志里有没有 (PARAM=...) 行。
//   2. 时间单位显式声明；复位用 task 统一，不散落 #xxx。
//   3. 断言用 task chk() 统一计数，结尾只输出一行 === RESULT: ... ===
//      （check_sim_logs.py 依赖这个约定）。
//   4. 必须有 watchdog：DUT 卡死时也要打印结论，否则日志看起来"没消息=通过"。
//   5. 渐变/遮罩类信号不要只断言"取值属于集合"，要断言单调性或比例曲线
//      —— 二值断言会把方向反了的 bug 判成 PASS。
// =====================================================================
module tb_<MODULE_NAME>;

    // ---- 时钟/复位（按 DUT 改频率）----
    localparam integer CLK_HALF_NS = 10;     // 10ns 半周期 = 50 MHz
    localparam integer TIMEOUT_NS  = 200_000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    // ---- DUT 端口 ----
    reg         din_vld = 1'b0;
    reg  [23:0] din     = 24'd0;
    wire        dout_vld;
    wire [23:0] dout;

    // ---- 计分板 ----
    integer nchk = 0;
    integer nerr = 0;

    // ---- DUT（参数覆盖放在这里；默认值与 RTL 保持一致，别在 TB 里改语义）----
    <module_name> #(
        .SOME_PARAM (16'd100)          // 若 RTL 里是 localparam，此行无效，见 header 第 1 条
    ) dut (
        .clk      (clk      ),
        .rst_n    (rst_n    ),
        .din_vld  (din_vld  ),
        .din      (din      ),
        .dout_vld (dout_vld ),
        .dout     (dout     )
    );

    // ---- 断言工具 ----
    task chk(input [127:0] tag, input [63:0] got, input [63:0] exp);
        begin
            nchk = nchk + 1;
            if (got !== exp) begin
                nerr = nerr + 1;
                $display("FAIL %0s: got %0h exp %0h  @%0t", tag, got, exp, $time);
            end
            else
                $display("OK   %0s: %0h", tag, got);
        end
    endtask

    // ---- 渐变类断言：采样序列必须单调（dir=+1 递增 / -1 递减）----
    // 用法：在需要观察的节拍调用 mono_sample(step, 当前值)
    real    mono_prev  = -1.0;
    integer mono_bad   = 0;
    task mono_sample(input real value, input integer dir);
        begin
            if (mono_prev >= 0.0) begin
                if ((dir > 0 && value + 1e-9 < mono_prev) ||
                    (dir < 0 && value - 1e-9 > mono_prev)) begin
                    mono_bad = mono_bad + 1;
                    $display("FAIL 非单调: prev=%0.3f now=%0.3f dir=%0d @%0t",
                             mono_prev, value, dir, $time);
                end
            end
            mono_prev = value;
        end
    endtask

    // ---- 激励 ----
    initial begin
        #200;
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // TODO: 阶段化激励，每段之间用 @(posedge clk) 推进，不用裸 # 延时
        din_vld <= 1'b1;
        din     <= 24'h123456;
        @(posedge clk);
        din_vld <= 1'b0;
        repeat (4) @(posedge clk);

        chk("dout 直通", dout, 24'h123456);

        // TODO: 每加一组激励就加一条 chk()，保持"一个判据一行证据"

        if (nerr == 0)
            $display("=== RESULT: PASS (%0d checks) ===", nchk);
        else
            $display("=== RESULT: FAIL (%0d/%0d checks) ===", nerr, nchk);
        $finish;
    end

    // ---- 看门狗：不要让它默默超时 ----
    initial begin
        #(TIMEOUT_NS);
        $display("=== RESULT: TIMEOUT (no conclusion within %0d ns) ===", TIMEOUT_NS);
        $finish;
    end

    // ---- 波形（按需打开；-debug typical 才需要）----
    // initial begin
    //     $dumpfile("tb_<MODULE_NAME>.vcd");
    //     $dumpvars(0, tb_<MODULE_NAME>);
    // end

endmodule
