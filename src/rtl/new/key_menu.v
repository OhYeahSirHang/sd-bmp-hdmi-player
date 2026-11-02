`timescale 1ns/1ps
// --------------------------------------------------------------------
// key_menu.v  v3: 双按键菜单控制状态机
// --------------------------------------------------------------------
// 按键布局 (仅2个按键):
//   KEY1 短按: 选中行下移 (图片/模式/颜色/效果 循环)
//   KEY1 长按(>=1s): 菜单显示/隐藏 切换 (菜单为一层OSD图层)
//   KEY2 短按: 当前行取值循环 (按当前行不同):
//       图片行 -> 切换下一张图片 (img_next 脉冲)
//       模式行 -> 原图/灰度/边缘/边缘彩色叠加/负片/黑白/红调/冷调/浮雕/色阶/线稿/锐化/模糊/复古/紫调/绿调/中值/坎尼 循环(17种)
//       颜色行 -> 黑/白/红/蓝/绿 循环 (控制正下方中文字幕颜色)
//       效果行 -> 淡入淡出/切入/随机线条/溶解 循环
//   任意短按自动显示菜单; 长按KEY1隐藏菜单
// --------------------------------------------------------------------
module key_menu (
    input              clk        , // 50MHz
    input              rst_n      ,
    // ---- 去抖后按键脉冲 (key_debounce) ----
    input              key1_down  ,
    input              key1_up    ,
    input              key2_down  ,
    input              key2_up    ,
    // ---- 输出 (50M域) ----
    output reg         img_next   , // 切换下一张图片脉冲
    output reg         vid_next   , // 切换下一段视频脉冲
    output reg [4:0]   mode       , //0..14原15种 + 15中值 + 16Canny近似 (菜单循环)
    output reg [2:0]   color_sel  , // 0=黑 1=白 2=红 3=蓝 4=绿
    output reg [3:0]   effect_sel , // 0淡入淡出 1切入 2随机线条 3溶解 4百叶窗 5中心扩散 6上下合拢 7棋盘格
    output reg         menu_show  , // 1: 显示右上角菜单
    output reg         media_sel  , // 0=图片 1=视频
    output reg [2:0]   menu_row     // 0=媒体 1=图片 2=模式 3=颜色 4=效果
);
//==================================================================
// 参数
//==================================================================
parameter [25:0] LONG_CNT = 26'd50_000_000;  // 长按判定: 1s (50MHz), TB可覆盖缩短

//==================================================================
// KEY1 长按/短按判定
//==================================================================
reg        k1_pressed;   // KEY1 按住中
reg [25:0] k1_cnt;       // 按住时长计数
reg        k1_long_done; // 已判定长按(防止重复)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        k1_pressed <= 1'b0;
        k1_cnt     <= 26'd0;
        k1_long_done <= 1'b0;
    end
    else if(key1_down) begin
        k1_pressed <= 1'b1;
        k1_cnt     <= 26'd0;
        k1_long_done <= 1'b0;
    end
    else if(key1_up) begin
        k1_pressed <= 1'b0;
    end
    else if(k1_pressed) begin
        if(k1_cnt == LONG_CNT - 26'd1) begin
            k1_cnt <= 26'd0;
            k1_long_done <= 1'b1;
        end
        else if(!k1_long_done)
            k1_cnt <= k1_cnt + 1'b1;
    end
end
// 短按脉冲: 松开时按住时长 < 1s
wire key1_short = key1_up && k1_pressed && !k1_long_done;
// 长按脉冲: 按住满1s
wire key1_long  = key1_down && 1'b0;   // 占位(实际用 k1_cnt 满标志)
reg  k1_long_ev;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) k1_long_ev <= 1'b0;
    else       k1_long_ev <= (k1_pressed && (k1_cnt == LONG_CNT - 26'd1)) && !k1_long_done;
end
//==================================================================
// KEY2 短按脉冲 (key_debounce 已给出, 直接用)
//==================================================================
//==================================================================
// 主控制
//==================================================================
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        img_next   <= 1'b0;
        vid_next   <= 1'b0;
        mode       <= 5'd0;
        color_sel  <= 3'd1;   // 默认白色字幕
        effect_sel <= 4'd0;
        menu_show  <= 1'b1;   // 上电默认显示菜单
        menu_row   <= 3'd0;
        media_sel  <= 1'b0;
    end
    else begin
        img_next <= 1'b0;
        vid_next <= 1'b0;
        // KEY1 长按: 切换菜单显示
        if(k1_long_ev)
            menu_show <= ~menu_show;
        // KEY1 短按: 选中行下移
        else if(key1_short) begin
            menu_show <= 1'b1;
            menu_row  <= (menu_row == 3'd4) ? 3'd0 : menu_row + 1'b1;
        end
        // KEY2 短按: 当前行取值循环
        else if(key2_down) begin
            menu_show <= 1'b1;
            case (menu_row)
            3'd0: begin
                media_sel <= ~media_sel;                        // 媒体行: 图片<->视频
            end
            3'd1: begin
                if(media_sel) vid_next <= 1'b1;   // 视频: 下一段
                else          img_next <= 1'b1;   // 图片: 下一张
            end
            3'd2: begin
                mode <= (mode == 5'd16) ? 5'd0 : mode + 1'b1;  // 模式循环 0..16 (17种)
            end
            3'd3: begin
                color_sel <= (color_sel == 3'd4) ? 3'd0 : color_sel + 1'b1; // 颜色循环
            end
            3'd4: begin
                effect_sel <= (effect_sel == 4'd7) ? 4'd0 : effect_sel + 1'b1; // 效果循环 0..7
            end
            default: ;
            endcase
        end
    end
end
endmodule
