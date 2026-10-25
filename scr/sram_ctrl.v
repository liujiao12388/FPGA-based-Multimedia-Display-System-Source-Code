//==========================================================================
// 模块：sram_ctrl —— 异步 SRAM 读写控制器（自研）
//--------------------------------------------------------------------------
// 器件：板载 IS61WV25616（512KB，256K×16，10ns 访问）。
// 时钟：100MHz（10ns）。每次读/写用约 4 拍完成，接口简单。
//
// 接口：req 拉高一拍发起；we=1 写、we=0 读；addr/wdata 给出；
//       ready 拉高一拍表示完成，读时 rdata 有效。
//==========================================================================
module sram_ctrl (
    input  wire        clk,
    input  wire        rst,
    // 用户侧
    input  wire        req,
    input  wire        we,
    input  wire [18:0] addr,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,
    output reg         ready,
    // SRAM 物理接口
    output reg  [18:0] sram_a,
    output reg         sram_ce_n,
    output reg         sram_we_n,
    output reg         sram_oe_n,
    output wire        sram_lb_n,
    output wire        sram_ub_n,
    inout  wire [15:0] sram_dq
);
    // 字节使能：始终全字访问（低/高字节都使能）
    assign sram_lb_n = 1'b0;
    assign sram_ub_n = 1'b0;

    // 三态数据总线：写时驱动，读时高阻
    reg         dq_drive;
    reg  [15:0] dq_out;
    assign sram_dq = dq_drive ? dq_out : 16'hzzzz;

    localparam S_IDLE=3'd0, S_SET=3'd1, S_W2=3'd2, S_W3=3'd3, S_CAP=3'd4, S_DONE=3'd5;
    reg [2:0] st;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st<=S_IDLE; sram_a<=0; sram_ce_n<=1; sram_we_n<=1; sram_oe_n<=1;
            dq_drive<=0; dq_out<=0; rdata<=0; ready<=0;
        end else begin
            ready <= 1'b0;
            case (st)
                S_IDLE: begin
                    sram_ce_n<=1; sram_we_n<=1; sram_oe_n<=1; dq_drive<=0;
                    if (req) st <= S_SET;
                end
                // 建立地址与控制
                S_SET: begin
                    sram_a <= addr;
                    sram_ce_n <= 1'b0;
                    if (we) begin
                        dq_out <= wdata; dq_drive <= 1'b1;
                        sram_we_n <= 1'b0; sram_oe_n <= 1'b1;   // 写
                    end else begin
                        dq_drive <= 1'b0;
                        sram_we_n <= 1'b1; sram_oe_n <= 1'b0;   // 读
                    end
                    st <= S_W2;
                end
                S_W2: st <= S_W3;       // 等待访问时间
                S_W3: st <= S_CAP;
                // 采样 / 结束
                S_CAP: begin
                    if (we) begin
                        sram_we_n <= 1'b1; dq_drive <= 1'b0;    // 写：拉高 WE 锁存
                    end else begin
                        rdata <= sram_dq;                       // 读：采样
                    end
                    st <= S_DONE;
                end
                S_DONE: begin
                    sram_ce_n<=1; sram_oe_n<=1; dq_drive<=0;
                    ready <= 1'b1;
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
