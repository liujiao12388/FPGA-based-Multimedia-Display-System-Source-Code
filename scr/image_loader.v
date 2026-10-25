//==========================================================================
// 模块：image_loader —— 从 TF 卡读 BMP 并解析，写入 SDRAM 帧缓存（自研）
//--------------------------------------------------------------------------
// 本模块【自己解析 BMP】：读取 BMP 文件头，取出像素数据偏移，从该偏移处
// 按 24 位 BGR 取像素，转成 RGB 写入帧缓存。
//
// BMP 结构（640×480 24 位）：
//   [0:1]   'BM'
//   [10:13] 像素数据偏移（=54，本模块解析得到并据此跳过文件头）
//   [18:21] 宽度
//   [22:25] 高度（正：自底向上）
//   [28:29] 位深（=24）
//   [54..]  像素数据：自底向上、每像素 3 字节 BGR、每行 1920 字节
//
// 自底向上：像素按原始顺序（自底向上）送出，由 frame_read_write 的
//           WRITE_V_FLIP=1 完成翻转。
//
// 卡布局：第 i 张 BMP 起始扇区 = IMG_BASE + i*SECT_PER_IMG（每张占 1801 扇区）。
//==========================================================================
module image_loader #(
    parameter FRAME_W      = 640,
    parameter FRAME_H      = 480,
    parameter IMG_BASE     = 32'd2049,
    parameter SECT_PER_IMG = 32'd1801
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  start_idx,
    output reg         load_done,
    output reg         sd_start,
    output reg  [31:0] sd_sector,
    input  wire        sd_init_done,
    input  wire [7:0]  sd_rd_data,
    input  wire        sd_rd_valid,
    input  wire        sd_done,
    output reg         wr_req,
    input  wire        wr_req_ack,
    output reg         wr_en,
    output reg  [31:0] wr_data,
    output wire        busy
);
    localparam TOTAL_PIX  = FRAME_W * FRAME_H;      // 307200
    localparam W_IDLE=2'd0, W_REQ=2'd1, W_STREAM=2'd2;

    reg [31:0] base_sec;
    reg        running;
    reg [1:0]  wst;
    reg [18:0] wr_pix;

    assign busy = running;

    wire frame_done = (wst == W_STREAM) && wr_en && (wr_pix == TOTAL_PIX-1);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            running  <= 1'b0;
            base_sec <= IMG_BASE;
        end else if (start && !running) begin
            running  <= 1'b1;
            base_sec <= IMG_BASE + start_idx*SECT_PER_IMG;
        end else if (frame_done) begin
            running  <= 1'b0;
        end
    end

    //==== 扇区读调度（等 SD 初始化 + 写侧就绪）====
    reg [11:0] sect_idx;
    reg        rd_busy;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_start<=0; sd_sector<=0; sect_idx<=0; rd_busy<=0;
        end else if (!sd_init_done) begin
            sd_start<=0; sect_idx<=0; rd_busy<=0;
        end else if (start && !running) begin
            sect_idx <= 12'd0; rd_busy <= 1'b0;
        end else if (!running || wst != W_STREAM) begin
            sd_start <= 1'b0;
        end else if (!rd_busy) begin
            if (sect_idx < SECT_PER_IMG[11:0]) begin
                sd_sector <= base_sec + sect_idx;
                sd_start  <= 1'b1;
                rd_busy   <= 1'b1;
            end else begin
                sd_start <= 1'b0;
            end
        end else begin
            sd_start <= 1'b0;
            if (sd_done) begin
                rd_busy  <= 1'b0;
                sect_idx <= sect_idx + 1'b1;
            end
        end
    end

    //==== BMP 头解析 + 字节→像素（自研）====
    reg [20:0] bcnt;           // 全局字节计数
    reg [31:0] data_off;       // 从 BMP 头解析出的像素数据偏移
    reg [15:0] bpp;            // 位深
    reg [1:0]  pbc;            // 像素内字节索引 0=B 1=G 2=R
    reg [7:0]  pb0, pb1;
    reg [23:0] pix;
    reg        pix_valid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bcnt<=0; data_off<=32'd54; bpp<=16'd24; pbc<=0; pb0<=0; pb1<=0;
            pix<=0; pix_valid<=0;
        end else begin
            pix_valid <= 1'b0;
            if (start && !running) begin
                bcnt <= 21'd0; pbc <= 2'd0;
            end else if (sd_rd_valid) begin
                // --- 解析 BMP 头关键字段 ---
                case (bcnt)
                    21'd10: data_off[7:0]   <= sd_rd_data;
                    21'd11: data_off[15:8]  <= sd_rd_data;
                    21'd12: data_off[23:16] <= sd_rd_data;
                    21'd13: data_off[31:24] <= sd_rd_data;
                    21'd28: bpp[7:0]        <= sd_rd_data;
                    21'd29: bpp[15:8]       <= sd_rd_data;
                    default: ;
                endcase
                // --- 像素数据（从数据偏移开始，每 3 字节 BGR）---
                if (bcnt >= data_off) begin
                    case (pbc)
                        2'd0: pb0 <= sd_rd_data;              // B
                        2'd1: pb1 <= sd_rd_data;              // G
                        2'd2: begin                           // R
                            pix       <= {sd_rd_data, pb1, pb0};   // {R,G,B}
                            pix_valid <= 1'b1;
                        end
                    endcase
                    pbc <= (pbc==2'd2) ? 2'd0 : (pbc + 2'd1);
                end
                bcnt <= bcnt + 1'b1;
            end
        end
    end

    //==== 写帧缓存 ====
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wst<=W_IDLE; wr_req<=0; wr_en<=0; wr_data<=0; wr_pix<=0; load_done<=0;
        end else begin
            load_done <= 1'b0;
            wr_en     <= 1'b0;
            case (wst)
                W_IDLE:  if (start && !running) begin wr_req<=1'b1; wst<=W_REQ; end
                W_REQ:   if (wr_req_ack) begin wr_req<=1'b0; wst<=W_STREAM; end
                W_STREAM: begin
                    if (pix_valid) begin
                        wr_en   <= 1'b1;
                        wr_data <= {pix, 8'h00};
                    end
                    if (wr_en) begin
                        wr_pix <= wr_pix + 1'b1;
                        if (wr_pix == TOTAL_PIX-1) begin
                            load_done <= 1'b1;
                            wst       <= W_IDLE;
                            wr_pix    <= 19'd0;
                        end
                    end
                end
                default: wst <= W_IDLE;
            endcase
        end
    end
endmodule
