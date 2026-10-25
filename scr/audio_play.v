//==========================================================================
// 模块：audio_play —— 从 SRAM 读样本，按 48kHz 输出（自研）
//--------------------------------------------------------------------------
// 音频数据已由 audio_loader 写入 SRAM（16 位单声道，地址 0 起）。
// load_done 后本模块按 48kHz 从 SRAM 连续读样本，扩为 24 位、左右相同，
// 输出 audio_valid/audio_left/audio_right 给 HDMI core；到末尾循环。
//
// SRAM 读口仲裁：load_busy=1 时让位（不读）；=0 时本模块占用读口。
//==========================================================================
module audio_play #(
    parameter FS_HZ  = 48_000,
    parameter CLK_HZ = 25_000_000,
    parameter NSAMP  = 19'd120000          // 音频样本总数
)(
    input  wire        clk,                // video_clk 25MHz
    input  wire        rst,
    input  wire        load_busy,          // audio_loader 写 SRAM 中（让位）
    output reg         sreq,
    output reg         swe,                // =0 读
    output reg  [18:0] saddr,
    input  wire        sready,
    input  wire [15:0] srdata,
    // 音频输出（100MHz 域；由顶层跨到 25MHz 域喂 core）
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right,
    output reg         samp_toggle         // 每个样本翻转一次（跨时钟域用）
);
    //---- 48kHz 节拍（小数累加）----
    reg [24:0] acc;
    wire sample_tick = (!load_busy) && (acc + FS_HZ >= CLK_HZ);

    always @(posedge clk or posedge rst) begin
        if (rst)                acc <= 25'd0;
        else if (load_busy)     acc <= 25'd0;
        else if (acc + FS_HZ >= CLK_HZ) acc <= acc + FS_HZ - CLK_HZ;
        else                    acc <= acc + FS_HZ;
    end

    //---- SRAM 读状态机 ----
    localparam R_IDLE=2'd0, R_WAIT=2'd1;
    reg [1:0]  rstate;
    reg [18:0] raddr;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rstate<=R_IDLE; sreq<=1'b0; swe<=1'b0; saddr<=19'd0; raddr<=19'd0;
            audio_left<=24'd0; audio_right<=24'd0; samp_toggle<=1'b0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    if (sample_tick) begin
                        saddr <= raddr; swe <= 1'b0; sreq <= 1'b1;
                        rstate <= R_WAIT;
                    end
                end
                R_WAIT: begin
                    sreq <= 1'b0;
                    if (sready) begin
                        audio_left  <= {srdata, 8'h00};   // 16位有符号→24位
                        audio_right <= {srdata, 8'h00};
                        samp_toggle <= ~samp_toggle;       // 通知 25MHz 域取样本
                        raddr <= (raddr == NSAMP-1) ? 19'd0 : (raddr + 1'b1);
                        rstate <= R_IDLE;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end
endmodule
