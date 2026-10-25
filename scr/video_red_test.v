//==========================================================================
// 模块：video_red_test —— 纯红测试图源
//--------------------------------------------------------------------------
// 与官方 video_source_test 结构【完全一致】（官方在 AC201 上验证过能用），
// 仅把像素数据由“蓝色渐变计数”改为固定的纯红 24'hFF0000。
// 这样排除任何我自己改动的同步逻辑，只验证“外部纯红数据能否显示”。
//
// 注：官方 video_source_test 的时序参数此处沿用 720p（与 core 配置一致）。
//==========================================================================
module video_red_test #(
    parameter HTOTAL  = 1650,
    parameter HACTIVE = 1280,
    parameter HFP     = 110,
    parameter HSA     = 40,
    parameter HBP     = 220,

    parameter VTOTAL  = 750,
    parameter VACTIVE = 720,
    parameter VFP     = 5,
    parameter VSA     = 5,
    parameter VBP     = 20
)(
    input  wire         I_clk,
    input  wire         I_rst,

    input  wire         I_tpg_trig_en,

    output reg          O_video_user,
    output reg          O_video_valid,
    output reg          O_video_last,
    output wire [23:0]  O_video_data,
    input  wire         I_video_ready
);

    localparam VBLANK = VTOTAL - VACTIVE;
    localparam HBLANK = HTOTAL - HACTIVE;

    reg        S_tpg_en;
    reg [13:0] S_col_cnt;
    reg [13:0] S_line_cnt;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)                 S_tpg_en <= 1'b0;
        else if (I_tpg_trig_en)    S_tpg_en <= 1'b1;
        else                       S_tpg_en <= S_tpg_en;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst || !S_tpg_en)                       S_col_cnt <= 14'd0;
        else if (S_col_cnt == HTOTAL - 1)             S_col_cnt <= 14'd0;
        else                                          S_col_cnt <= S_col_cnt + 1'b1;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst || !S_tpg_en)                       S_line_cnt <= 14'd0;
        else if (S_col_cnt == HTOTAL - 1) begin
            if (S_line_cnt == VTOTAL - 1)             S_line_cnt <= 14'd0;
            else                                      S_line_cnt <= S_line_cnt + 1'b1;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst || !S_tpg_en)                       O_video_valid <= 1'b0;
        else if (S_line_cnt >= VBLANK && S_col_cnt >= HBLANK) O_video_valid <= 1'b1;
        else                                          O_video_valid <= 1'b0;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst || !S_tpg_en)                       O_video_user <= 1'b0;
        else if (S_line_cnt == VBLANK && S_col_cnt == HBLANK) O_video_user <= 1'b1;
        else                                          O_video_user <= 1'b0;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst || !S_tpg_en)                       O_video_last <= 1'b0;
        else if (S_line_cnt >= VBLANK && S_col_cnt == HTOTAL - 1) O_video_last <= 1'b1;
        else                                          O_video_last <= 1'b0;
    end

    // 纯红
    assign O_video_data = 24'hFF0000;

endmodule
