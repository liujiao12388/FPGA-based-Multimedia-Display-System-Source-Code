//==========================================================================
// 模块：test_pattern_write —— 测试图案写入器（替代 TF 卡读图）
//--------------------------------------------------------------------------
// 作用：不接 TF 卡，直接产生一帧 640×480 的渐变测试图，通过
//       frame_read_write 的写接口写进 SDRAM 帧缓存，验证
//       “图案 → SDRAM → 读出 → 显示” 通路。
//
// 写协议（照官方 sd_card_bmp/bmp_read 的用法）：
//   1) 拉高 write_req，保持到 write_req_ack=1
//   2) ack 后，逐拍拉高 write_en 并给出 write_data（RGB 在高 24 位）
//   3) 共送 640×480 = 307200 个像素
//
// 图案：R = 列低 8 位，G = 行低 8 位，B = 0（横红纵绿的双向渐变）
//==========================================================================
module test_pattern_write #(
    parameter FRAME_W      = 640,
    parameter FRAME_H      = 480,
    parameter FRAME_PIXELS = 640*480
)(
    input  wire        clk,             // 写时钟（sd_card_clk，100MHz）
    input  wire        rst,             // 高有效复位（接 rst_all）
    output reg         write_req,       // 写请求，保持到 ack
    input  wire        write_req_ack,   // 请求应答
    output wire        write_en,        // 逐像素写使能
    output wire [31:0] write_data       // 逐像素数据 {R,G,B,8'b0}
);

    localparam ST_IDLE = 3'd0,
               ST_WAIT = 3'd1,
               ST_GAP  = 3'd2,      // ack 后等几拍，避开 frame_fifo 的 FIFO 清零窗口
               ST_DATA = 3'd3,
               ST_DONE = 3'd4;

    reg [2:0]  state;
    reg [3:0]  gap_cnt;
    reg [9:0]  col;          // 0..639
    reg [9:0]  row;          // 0..479

    wire last_pixel = (row == FRAME_H - 1) && (col == FRAME_W - 1);

    // write_en / write_data 组合给出，与 col/row 同步（同一拍采样）
    // 注意：不能直接取 col[7:0]/row[7:0]——那只覆盖 0~255，渐变会每 256 像素回绕。
    //       这里按屏幕尺寸缩放，使渐变铺满整屏：
    //         R 跨 640 列映射到 0~255：系数 256/640 ≈ 205/512
    //         G 跨 480 行映射到 0~255：系数 256/480 ≈ 273/512
    wire [17:0] r_scaled = col * 18'd205;   // col * 205
    wire [17:0] g_scaled = row * 18'd273;   // row * 273
    assign write_en   = (state == ST_DATA);
    assign write_data = {r_scaled[16:9], g_scaled[16:9], 8'h00, 8'b0};  // R,G,B=0

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= ST_IDLE;
            write_req <= 1'b0;
            gap_cnt   <= 4'd0;
            col       <= 10'd0;
            row       <= 10'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    write_req <= 1'b1;
                    col       <= 10'd0;
                    row       <= 10'd0;
                    state     <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (write_req_ack) begin
                        write_req <= 1'b0;
                        gap_cnt   <= 4'd0;
                        state     <= ST_GAP;
                    end
                end
                ST_GAP: begin
                    // 等 6 拍，让 frame_fifo 完成 FIFO 清零、进入等待
                    if (gap_cnt == 4'd5) state <= ST_DATA;
                    else                 gap_cnt <= gap_cnt + 4'd1;
                end
                ST_DATA: begin
                    if (last_pixel) begin
                        state <= ST_DONE;      // 最后一个像素已在本拍送出
                    end
                    else if (col == FRAME_W - 1) begin
                        col <= 10'd0;
                        row <= row + 10'd1;
                    end
                    else begin
                        col <= col + 10'd1;
                    end
                end
                ST_DONE: begin
                    state <= ST_DONE;          // 写完静止（静态图）
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
