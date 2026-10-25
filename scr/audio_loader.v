//==========================================================================
// 模块：audio_loader —— TF卡音频样本 → 写入 SRAM（自研）
//--------------------------------------------------------------------------
// 从卡上音频起始扇区顺序读出 16 位单声道样本（小端），写入 SRAM 递增地址。
// 卡布局：音频从 AUDIO_SECTOR 起，共 AUDIO_SECTORS 扇区（每扇区 256 样本）。
//==========================================================================
module audio_loader #(
    parameter AUDIO_SECTOR  = 32'd5651,
    parameter AUDIO_SECTORS = 16'd469
)(
    input  wire        clk,
    input  wire        rst,
    output reg         sd_start,
    output reg  [31:0] sd_sector,
    input  wire        sd_init_done,
    input  wire [7:0]  sd_rd_data,
    input  wire        sd_rd_valid,
    input  wire        sd_done,
    // SRAM 写
    output reg  [18:0] saddr,
    output reg         sreq,
    output reg         swe,
    output wire [15:0] swdata,
    input  wire        sready,
    output reg         load_done
);
    //---- 扇区读调度 ----
    reg [8:0]  sect_idx;
    reg        rd_busy;
    always @(posedge clk or posedge rst) begin
        if (rst) begin sd_start<=0; sd_sector<=0; sect_idx<=0; rd_busy<=0; end
        else if (!sd_init_done) begin sd_start<=0; sect_idx<=0; rd_busy<=0; end
        else if (!rd_busy) begin
            if (sect_idx < AUDIO_SECTORS) begin
                sd_sector <= AUDIO_SECTOR + sect_idx; sd_start<=1'b1; rd_busy<=1'b1;
            end else sd_start<=1'b0;
        end else begin
            sd_start<=1'b0;
            if (sd_done) begin rd_busy<=1'b0; sect_idx<=sect_idx+1'b1; end
        end
    end
    wire read_all = (sect_idx >= AUDIO_SECTORS) && !rd_busy;

    //---- 字节 → 16 位样本（小端：先低后高）----
    reg       lo_hi;
    reg [7:0] lo_byte;
    reg [15:0] samp;
    reg       samp_valid;
    always @(posedge clk or posedge rst) begin
        if (rst) begin lo_hi<=0; lo_byte<=0; samp<=0; samp_valid<=0; end
        else begin
            samp_valid <= 1'b0;
            if (sd_rd_valid) begin
                if (!lo_hi) begin lo_byte<=sd_rd_data; lo_hi<=1'b1; end
                else begin samp<={sd_rd_data,lo_byte}; samp_valid<=1'b1; lo_hi<=1'b0; end
            end
        end
    end

    //---- 写 SRAM（简单三段）----
    localparam W_IDLE=2'd0, W_REQ=2'd1, W_WAIT=2'd2;
    reg [1:0]  wst;
    reg [18:0] waddr;
    reg [15:0] wdata_r;
    assign swdata = wdata_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wst<=W_IDLE; saddr<=0; sreq<=0; swe<=1'b1; waddr<=0; wdata_r<=0; load_done<=0;
        end else begin
            load_done <= 1'b0;
            case (wst)
                W_IDLE: if (samp_valid) begin wdata_r<=samp; wst<=W_REQ; end
                W_REQ:  begin saddr<=waddr; swe<=1'b1; sreq<=1'b1; wst<=W_WAIT; end
                W_WAIT: if (sready) begin
                            sreq<=1'b0; waddr<=waddr+1'b1; wst<=W_IDLE;
                        end
                default: wst<=W_IDLE;
            endcase
            // 全部读完且无待写 → 完成
            if (read_all && wst==W_IDLE && !samp_valid) load_done<=1'b1;
        end
    end
endmodule
