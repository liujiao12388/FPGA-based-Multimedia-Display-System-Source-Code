//==========================================================================
// 模块：slideshow_ctrl —— 图片轮播/切换状态机（自研）
//--------------------------------------------------------------------------
// 功能：
//   · key_next 脉冲 → 切到下一张图
//   · key_auto 脉冲 → 启动/停止自动轮播
//   · 自动轮播时，每 PERIOD 拍自动切下一张
//   · 输出 load_start 脉冲 + load_idx（要加载哪张），收到 load_done 后更新当前图
//
// 说明：图片张数 img_count 由上层（读卡头部）给出。
//==========================================================================
module slideshow_ctrl #(
    parameter PERIOD = 32'd300_000_000   // 自动轮播周期 @100MHz = 3 秒
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        key_next,      // 下一张（脉冲）
    input  wire        key_auto,      // 启停轮播（脉冲）
    input  wire        ready,         // SD 就绪（= sd_init_done），就绪后才首次加载
    input  wire [2:0]  img_count,     // 图片张数
    input  wire        load_done,     // 一帧加载完成（脉冲）
    output reg         load_start,    // 触发加载（脉冲）
    output reg  [1:0]  load_idx,      // 要加载的图片索引
    output reg  [1:0]  img_idx,       // 当前显示的图片索引
    output reg         auto_play      // 轮播开启标志（可接 LED）
);
    reg [1:0]  busy;                  // 0=空闲 1=正在加载（防止重入）
    reg [31:0] auto_cnt;
    reg        auto_tick;
    reg        started;               // 是否已完成首次加载

    // 自动计时
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            auto_cnt <= 32'd0; auto_tick <= 1'b0;
        end else begin
            auto_tick <= 1'b0;
            if (auto_play && !busy) begin
                if (auto_cnt >= PERIOD) begin auto_cnt <= 32'd0; auto_tick <= 1'b1; end
                else auto_cnt <= auto_cnt + 32'd1;
            end else begin
                auto_cnt <= 32'd0;
            end
        end
    end

    // 主状态：切换 / 轮播
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy<=1'b0; load_start<=1'b0; load_idx<=2'd0; img_idx<=2'd0;
            auto_play<=1'b0; started<=1'b0;
        end else begin
            load_start <= 1'b0;

            // 启停轮播
            if (key_auto) auto_play <= ~auto_play;

            if (!busy) begin
                // 上电首次：等 SD 就绪后加载第 0 张
                if (!started && ready && img_count != 0) begin
                    load_idx   <= 2'd0;
                    load_start <= 1'b1;
                    busy       <= 1'b1;
                    started    <= 1'b1;
                end
                // 手动下一张
                else if (key_next && img_count != 0) begin
                    load_idx   <= (img_idx + 2'd1 >= img_count) ? 2'd0 : (img_idx + 2'd1);
                    load_start <= 1'b1;
                    busy       <= 1'b1;
                end
                // 自动轮播到下一张
                else if (auto_play && auto_tick && img_count != 0) begin
                    load_idx   <= (img_idx + 2'd1 >= img_count) ? 2'd0 : (img_idx + 2'd1);
                    load_start <= 1'b1;
                    busy       <= 1'b1;
                end
            end else begin
                // 加载完成 → 更新当前图，回到空闲
                if (load_done) begin
                    img_idx <= load_idx;
                    busy    <= 1'b0;
                end
            end
        end
    end
endmodule
