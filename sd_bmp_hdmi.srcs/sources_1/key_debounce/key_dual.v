// --------------------------------------------------------------------
// key_dual.v
// 单按键复用：短按(<1s)输出 key_short 脉冲，长按(>=1s)输出 key_long 脉冲
// 用途：key_short -> 切换下一张图片；key_long -> 切换图像处理模式
// 内部例化 key_debounce 完成 20ms 消抖，本模块只做长短按计时判定
// --------------------------------------------------------------------
module key_dual(
       input       clk        , //50M时钟
       input       rst_n      ,
       input       key_in     ,
       output      key_short  , //短按脉冲：切换下一张图片
       output      key_long     //长按脉冲：切换图像处理模式
    );
//长按判定时间：1s @50MHz
localparam  LONG_CNT = 26'd50_000_000 - 1'b1;
wire        key_down ;
wire        key_up   ;
reg  [25:0] cnt      ; //长按计时
reg         long_flag; //已判定为长按的标志
reg         long_pulse_r;

key_debounce u_key_debounce(
       .clk         (clk     ), //50M的时钟输入  
       .rst_n       (rst_n   ),
       .key_in      (key_in  ),
       .key_down    (key_down), //按键按下产生一个高电平脉冲
       .key_up      (key_up  )  //按键松开产生一个高电平脉冲
    );
//长按计时：按下开始计数，松开清零；到1s判定长按并饱和
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cnt       <= 'd0;
        long_flag <= 1'b0;
    end
    else if(key_down) begin
        cnt       <= 'd0;
        long_flag <= 1'b0;
    end
    else if(key_up) begin
        cnt       <= 'd0;
    end
    else if(cnt == LONG_CNT) begin
        long_flag <= 1'b1;   //计时到1s，标记为长按
    end
    else if(!long_flag) begin
        cnt <= cnt + 1'b1;
    end
    else begin
        cnt <= cnt;
    end
end
//长按脉冲：计时到1s的那一拍产生（只产生一次）
assign key_long = (cnt == LONG_CNT) && (!long_flag);
//短按脉冲：在1s内松开，且未被判定为长按
assign key_short = key_up && (cnt < LONG_CNT) && (!long_flag);
endmodule
