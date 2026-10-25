//==========================================================================
// 模块：sd_spi_driver —— SD/TF 卡 SPI 模式驱动（自研，针对 SDHC/SDXC 卡）
//--------------------------------------------------------------------------
// SPI 模式初始化（CMD0→CMD8→CMD55/ACMD41→CMD58），然后按固定扇区读一个
// 512 字节扇区（CMD17）。不含文件系统。
//
// 命令字段由“当前命令类型 cur_op”组合派生（唯一驱动源，避免多驱动）。
// 状态机只更新 cur_op 与流程状态。
//
// SPI 模式 0（上升沿采样）。初始化 1MHz，读数据 12.5MHz。
//==========================================================================
module sd_spi_driver #(
    parameter DIV_SLOW = 8'd49,   // 100MHz/(2*50)=1MHz
    parameter DIV_FAST = 8'd3     // 100MHz/(2*4)=12.5MHz
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] sector,
    output reg         spi_clk,
    output reg         spi_cs_n,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output reg  [7:0]  rd_data,
    output reg         rd_valid,
    output reg         init_done,
    output reg         done,
    output reg         err,
    // 诊断：出错时 dbg[3]=1, dbg[2:0]=出错时的命令(0=CMD0,1=CMD8,2=CMD55,3=ACMD41,4=CMD58,5=READ)
    //       正常时 dbg[3]=0, dbg[2:0]=当前状态
    output reg  [3:0]  dbg
);
    //---- 半周期时基 ----
    reg [7:0] bdiv, div_cur;
    wire tick = (bdiv == div_cur);
    always @(posedge clk or posedge rst)
        if (rst) bdiv <= 8'd0; else bdiv <= tick ? 8'd0 : bdiv + 8'd1;

    //---- SPI 字节引擎 ----
    reg be_start, be_busy, be_done;
    reg [7:0] be_tx, be_txr, be_rxr;
    wire [7:0] be_rx = be_rxr;
    reg [2:0] be_bit; reg be_ph;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            be_busy<=0; be_done<=0; be_bit<=0; be_ph<=0;
            be_txr<=8'hFF; be_rxr<=8'hFF; spi_clk<=0; spi_mosi<=1;
        end else begin
            be_done <= 0;
            if (!be_busy) begin
                if (be_start) begin
                    be_busy<=1; be_bit<=0; be_ph<=0; be_txr<=be_tx; be_rxr<=0;
                    spi_clk<=0; spi_mosi<=be_tx[7];
                end
            end else if (tick) begin
                if (!be_ph) begin spi_clk<=1; be_rxr<={be_rxr[6:0],spi_miso}; be_ph<=1; end
                else begin
                    spi_clk<=0; be_ph<=0;
                    if (be_bit==7) begin be_busy<=0; be_done<=1; end
                    else begin be_bit<=be_bit+1'b1; spi_mosi<=be_txr[6]; be_txr<={be_txr[6:0],1'b1}; end
                end
            end
        end
    end

    //---- 命令常量 ----
    localparam CMD0=8'h40, CMD8=8'h48, CMD55=8'h77, ACMD41=8'h69,
               CMD58=8'h7A, CMD17=8'h51;
    localparam OP_CMD0=3'd0, OP_CMD8=3'd1, OP_CMD55=3'd2, OP_ACMD41=3'd3,
               OP_CMD58=3'd4, OP_READ=3'd5;

    reg [2:0] cur_op;            // 当前命令类型（唯一被时序更新的命令相关寄存器）

    //---- 命令字段：由 cur_op 组合派生（唯一驱动源）----
    wire [7:0]  cur_cmd = (cur_op==OP_CMD0)  ? CMD0   :
                          (cur_op==OP_CMD8)  ? CMD8   :
                          (cur_op==OP_CMD55) ? CMD55  :
                          (cur_op==OP_ACMD41)? ACMD41 :
                          (cur_op==OP_CMD58) ? CMD58  : CMD17;
    wire [31:0] cur_arg = (cur_op==OP_CMD8)  ? 32'h000001AA   :
                          (cur_op==OP_ACMD41)? 32'h40000000   :
                          (cur_op==OP_READ)  ? sector         : 32'h0;
    wire [7:0]  cur_crc = (cur_op==OP_CMD0) ? 8'h95 :
                          (cur_op==OP_CMD8) ? 8'h87 : 8'hFF;
    wire [2:0]  cur_extra = (cur_op==OP_CMD8 || cur_op==OP_CMD58) ? 3'd4 : 3'd0;

    //---- 状态机 ----
    localparam S_POWER=4'd0, S_CMD=4'd1, S_R1=4'd2, S_EXTRA=4'd3, S_AFTER=4'd4,
               S_READY=4'd5, S_TOKEN=4'd6, S_DATA=4'd7, S_CRC=4'd8, S_DONE=4'd9, S_ERR=4'd10;
    reg [3:0]  st;
    reg [2:0]  si;
    reg [9:0]  dcnt;
    reg [19:0] tmo;
    reg [7:0]  pwr;
    reg [7:0]  r1;
    reg [2:0]  err_code;      // 出错时锁存的命令码

    // 诊断码：出错→{1, 失败命令}; 初始化完成→0111; 进行中→{0, 当前命令}
    always @(*) begin
        if (err)           dbg = {1'b1, err_code};
        else if (init_done) dbg = 4'b0111;
        else               dbg = {1'b0, cur_op};
    end

    wire [7:0] cmd_byte = (si==0)?cur_cmd:(si==1)?cur_arg[31:24]:
                          (si==2)?cur_arg[23:16]:(si==3)?cur_arg[15:8]:
                          (si==4)?cur_arg[7:0]:cur_crc;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st<=S_POWER; si<=0; dcnt<=0; tmo<=0; pwr<=0;
            spi_cs_n<=1; rd_data<=0; rd_valid<=0; init_done<=0; done<=0; err<=0;
            be_start<=0; be_tx<=8'hFF; div_cur<=DIV_SLOW; r1<=8'hFF; cur_op<=OP_CMD0;
        end else begin
            be_start <= 0; rd_valid <= 0; done <= 0;
            case (st)
            //-- 上电送 80 clk --//
            S_POWER: begin
                spi_cs_n<=1; div_cur<=DIV_SLOW; cur_op<=OP_CMD0;
                if (be_done) begin
                    pwr<=pwr+1;
                    if (pwr==9) begin spi_cs_n<=0; si<=0; tmo<=0; st<=S_CMD; end
                    else begin be_start<=1; be_tx<=8'hFF; end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            //-- 发命令 6 字节 --//
            S_CMD: begin
                div_cur<=DIV_SLOW;
                if (be_done) begin
                    if (si==5) begin si<=0; tmo<=0; st<=S_R1; end
                    else si<=si+1;                 // 推进索引，下拍再发
                end else if (!be_busy && !be_start) begin
                    be_start<=1; be_tx<=cmd_byte;
                end
            end
            //-- 等 R1 --//
            S_R1: begin
                if (be_done) begin
                    if (!be_rx[7]) begin r1<=be_rx; tmo<=0; dcnt<=0;
                        st <= (cur_extra!=0) ? S_EXTRA : S_AFTER;
                    end else begin
                        tmo<=tmo+1; if (tmo[19:16]==4'hF) st<=S_ERR;
                        be_start<=1; be_tx<=8'hFF;
                    end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            //-- 读额外字节 --//
            S_EXTRA: begin
                if (be_done) begin
                    if (dcnt==cur_extra-1) begin dcnt<=0; st<=S_AFTER; end
                    else begin dcnt<=dcnt+1; be_start<=1; be_tx<=8'hFF; end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            //-- 决定下一步：更新 cur_op --//
            S_AFTER: begin
                if (cur_op==OP_READ) st <= S_TOKEN;
                else case (cur_op)
                    OP_CMD0:   begin cur_op<=OP_CMD8;   si<=0; st<=S_CMD; end
                    OP_CMD8:   begin cur_op<=OP_CMD55;  si<=0; st<=S_CMD; end
                    OP_CMD55:  begin cur_op<=OP_ACMD41; si<=0; st<=S_CMD; end
                    OP_ACMD41: begin
                        if (r1==8'h00) begin cur_op<=OP_CMD58; si<=0; st<=S_CMD; end
                        else           begin cur_op<=OP_CMD55; si<=0; st<=S_CMD; end
                    end
                    OP_CMD58:  begin st<=S_READY; end
                    default:   st<=S_ERR;
                endcase
            end
            //-- 就绪 --//
            S_READY: begin
                init_done<=1;
                if (start) begin cur_op<=OP_READ; si<=0; dcnt<=0; tmo<=0; st<=S_CMD; end
            end
            //-- 等数据令牌 --//
            S_TOKEN: begin
                div_cur<=DIV_FAST;
                if (be_done) begin
                    if (be_rx==8'hFE) begin dcnt<=0; st<=S_DATA; end
                    else begin tmo<=tmo+1; if (tmo[19:16]==4'hF) st<=S_ERR; be_start<=1; be_tx<=8'hFF; end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            //-- 读 512 字节 --//
            S_DATA: begin
                if (be_done) begin
                    rd_data<=be_rx; rd_valid<=1;
                    if (dcnt==511) begin dcnt<=0; st<=S_CRC; end
                    else begin dcnt<=dcnt+1; be_start<=1; be_tx<=8'hFF; end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            //-- 读 2 字节 CRC --//
            S_CRC: begin
                if (be_done) begin
                    if (dcnt==1) begin dcnt<=0; st<=S_DONE; end
                    else begin dcnt<=dcnt+1; be_start<=1; be_tx<=8'hFF; end
                end else if (!be_busy && !be_start) begin be_start<=1; be_tx<=8'hFF; end
            end
            S_DONE: begin done<=1; st<=S_READY; end
            S_ERR:  begin err<=1; err_code<=cur_op; end
            default: st<=S_ERR;
            endcase
        end
    end
endmodule
