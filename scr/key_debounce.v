//==========================================================================
// 模块：key_debounce —— 按键消抖 + 按下脉冲（自研）
//--------------------------------------------------------------------------
// 功能：对机械按键去抖，并在“按下”时输出一个单周期脉冲（用于计数/触发）。
//       按键低有效（按下=0）。
//
// 原理：对输入连续采样，只有电平稳定保持 CNT_MAX 拍才认为是有效电平变化。
//==========================================================================
module key_debounce #(
    parameter CNT_MAX   = 20'd500_000,   // 消抖时间：500000@100MHz=5ms
    parameter ACTIVE_LOW = 1             // 1=按键按下为低电平
)(
    input  wire clk,          // 100MHz
    input  wire rst,
    input  wire key_in,       // 原始按键输入
    output reg  key_press     // 按下脉冲（单周期）
);
    reg [19:0] cnt;
    reg        key_sync;      // 当前滤波后的按键电平（0=按下）
    reg        key_sync_d;

    wire key_level = ACTIVE_LOW ? ~key_in : key_in;   // 1=按下

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt        <= 20'd0;
            key_sync   <= 1'b0;
            key_sync_d <= 1'b0;
            key_press  <= 1'b0;
        end else begin
            key_press <= 1'b0;
            // 输入与当前稳定值不同 → 计数；计满则确认变化
            if (key_level != key_sync) begin
                if (cnt == CNT_MAX) begin
                    key_sync <= key_level;     // 确认新电平
                    cnt      <= 20'd0;
                end else begin
                    cnt <= cnt + 20'd1;
                end
            end else begin
                cnt <= 20'd0;
            end
            // 检测 key_sync 的上升沿（按下瞬间）→ 输出脉冲
            key_sync_d <= key_sync;
            if (key_sync & ~key_sync_d)
                key_press <= 1'b1;
        end
    end
endmodule
