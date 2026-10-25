//==========================================================================
// 模块：video_solid_red —— 纯红测试图源（AXI-stream）
//--------------------------------------------------------------------------
// 结构与官方 video_source_test 完全一致（保证满足 core 的 AXI 协议），
// 只把像素数据固定为纯红 24'hFF0000，并去掉内部渐变计数器。
//
// 时序参数须与 HDMI core 的配置一致（此处 720p：1650×750），
// 否则数据不会落在 core 的有效显示区。
//==========================================================================
module video_solid_red #(
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
    input  wire        I_clk,
    input  wire        I_rst,

    output reg         O_video_user,   // SOF
    output reg         O_video_valid,  // 有效像素
    output reg         O_video_last,   // 行尾
    output reg  [23:0] O_video_data    // 像素数据
);

    localparam VBLANK = VTOTAL - VACTIVE;
    localparam HBLANK = HTOTAL - HACTIVE;

    reg [13:0] S_col_cnt;
    reg [13:0] S_line_cnt;

    // 列计数
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_col_cnt <= 14'd0;
        else if (S_col_cnt == HTOTAL - 1)
            S_col_cnt <= 14'd0;
        else
            S_col_cnt <= S_col_cnt + 14'd1;
    end

    // 行计数
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_line_cnt <= 14'd0;
        else if (S_col_cnt == HTOTAL - 1) begin
            if (S_line_cnt == VTOTAL - 1)
                S_line_cnt <= 14'd0;
            else
                S_line_cnt <= S_line_cnt + 14'd1;
        end
    end

    // 有效像素
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            O_video_valid <= 1'b0;
        else if (S_line_cnt >= VBLANK && S_col_cnt >= HBLANK)
            O_video_valid <= 1'b1;
        else
            O_video_valid <= 1'b0;
    end

    // SOF：第一行有效区首像素
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            O_video_user <= 1'b0;
        else if (S_line_cnt == VBLANK && S_col_cnt == HBLANK)
            O_video_user <= 1'b1;
        else
            O_video_user <= 1'b0;
    end

    // 行尾
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            O_video_last <= 1'b0;
        else if (S_line_cnt >= VBLANK && S_col_cnt == HTOTAL - 1)
            O_video_last <= 1'b1;
        else
            O_video_last <= 1'b0;
    end

    // 纯红像素
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            O_video_data <= 24'd0;
        else
            O_video_data <= 24'hFF0000;   // {R=FF, G=00, B=00}
    end

endmodule
