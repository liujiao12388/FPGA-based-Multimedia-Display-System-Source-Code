//==========================================================================
// 模块：video_sdram_test —— 测试图案 → SDRAM 帧缓存 → HDMI 显示
//--------------------------------------------------------------------------
// 目的：验证“图案 → SDRAM 帧缓存 → 读出 → HDMI 显示”整条通路。
//       不接 TF 卡，用 test_pattern_write 直接产生一帧渐变图写入 SDRAM。
//
// 结构（SDRAM 部分照赛题参考工程 lab_ex4_tf 的接法）：
//   sys_pll(100M/125M/125M) + video_pll(25M/125M)
//   test_pattern_write  ──写接口──>  frame_read_write  <──  sdram（控制器）
//   video_timing_data   ──读请求──>                        └─ 读出像素
//   video_delay         <──读出──   （取出 RGB，附同步信号）
//   → video_rgb_to_axis → HDMI core → phy → 引脚
//==========================================================================
module video_sdram_test (
    input  wire clk,          // 板载 50MHz（K14）
    input  wire rst_n,        // 复位（H14）

    output wire HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P
);

    // ---- 参数 ----
    localparam MEM_DATA_BITS = 32;
    localparam ADDR_BITS     = 21;
    localparam FRAME_PIXELS  = 24'd307200;   // 640*480
    localparam BUF0_ADDR     = 24'd0;
    localparam BUF1_ADDR     = 24'd307200;

    // ---- 时钟/复位 ----
    wire sys_pll_lock, video_pll_lock;
    wire sd_card_clk, ext_mem_clk, ext_mem_clk_sft;   // 100M / 125M / 125M
    wire video_clk, hdmi_5x_clk;                       // 25M / 125M
    wire rst_all;

    // 统一复位：等两个 PLL 锁定后延时释放
    reg [19:0] rst_cnt = 20'd0;
    reg        rst_all_reg = 1'b1;
    always @(posedge clk) begin
        if (!rst_n) begin
            rst_cnt <= 20'd0; rst_all_reg <= 1'b1;
        end else if (!rst_all_reg) begin
            rst_all_reg <= 1'b0;
        end else if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt < 20'd1_000_000) begin rst_cnt <= rst_cnt + 1'b1; rst_all_reg <= 1'b1; end
            else rst_all_reg <= 1'b0;
        end else begin
            rst_cnt <= 20'd0; rst_all_reg <= 1'b1;
        end
    end
    assign rst_all = rst_all_reg;

    sys_pll U_sys_pll (
        .refclk(clk), .reset(1'b0), .extlock(sys_pll_lock),
        .clk0_out(sd_card_clk), .clk1_out(ext_mem_clk), .clk2_out(ext_mem_clk_sft)
    );
    video_pll U_video_pll (
        .refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
        .clk0_out(video_clk), .clk1_out(hdmi_5x_clk)
    );

    // ---- SDRAM 控制器接口信号 ----
    wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
    wire App_wr_en, App_rd_en, Sdr_rd_en;                    // 单比特使能
    wire [ADDR_BITS-1:0]     App_wr_addr_w, App_rd_addr_w;   // 21 位地址
    wire [MEM_DATA_BITS-1:0] App_wr_din_w, Sdr_rd_dout_w;    // 32 位数据
    wire [3:0]               App_wr_dm_w;                    // 4 位字节掩码

    // ---- 帧缓存 写/读 接口信号 ----
    wire        sd_wr_req, sd_wr_ack, sd_wr_en, frame_write_finish;
    wire [31:0] sd_wr_data;
    wire [1:0]  write_buf_idx = 2'd0, disp_buf_idx = 2'd0;

    wire        vread_req, vread_ack, vread_en;
    wire [31:0] vread_data;

    // ---- 视频时序与读出 ----
    wire hs_0, vs_0, de_0, hs, vs, de;
    wire [23:0] vout_data_raw, vout_data;
    wire display_valid;

    // 显示有效：复位释放后延时一小段（等 SDRAM 初始化 + 写完一帧）再开
    reg [21:0] dv_cnt = 22'd0;
    always @(posedge video_clk) if (dv_cnt != 22'h3FFFFF) dv_cnt <= dv_cnt + 1'b1;
    assign display_valid = (dv_cnt == 22'h3FFFFF);

    // ---- SDRAM 控制器 ----
    sdram U_sdram (
        .Clk              (ext_mem_clk),
        .Clk_sft          (ext_mem_clk_sft),
        .Rst              (rst_all),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr_w),
        .App_wr_dm        (App_wr_dm_w),
        .App_wr_din       (App_wr_din_w),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr_w),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout_w)
    );

    // ---- 测试图案写入器（替代 TF 卡读图，写 buffer0）----
    test_pattern_write U_pattern (
        .clk            (sd_card_clk),
        .rst            (rst_all),
        .write_req      (sd_wr_req),
        .write_req_ack  (sd_wr_ack),
        .write_en       (sd_wr_en),
        .write_data     (sd_wr_data)
    );

    // ---- 帧缓存管理 ----
    frame_read_write #(
        .WRITE_V_FLIP (0),      // 测试图不是 BMP，不需要翻转
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) U_frame (
        .mem_clk           (ext_mem_clk),
        .rst               (rst_all),
        .Sdr_init_done     (Sdr_init_done),
        .Sdr_init_ref_vld  (Sdr_init_ref_vld),
        .Sdr_busy          (Sdr_busy),
        .App_rd_en         (App_rd_en),
        .App_rd_addr       (App_rd_addr_w),
        .Sdr_rd_en         (Sdr_rd_en),
        .Sdr_rd_dout       (Sdr_rd_dout_w),
        .read_clk          (video_clk),
        .read_req          (vread_req),
        .read_req_ack      (vread_ack),
        .read_finish       (),
        .read_addr_0       (BUF0_ADDR),
        .read_addr_1       (BUF1_ADDR),
        .read_addr_2       (24'd0),
        .read_addr_3       (24'd0),
        .read_addr_index   (disp_buf_idx),
        .read_len          (FRAME_PIXELS),
        .read_en           (vread_en),
        .read_data         (vread_data),
        .App_wr_en         (App_wr_en),
        .App_wr_addr       (App_wr_addr_w),
        .App_wr_din        (App_wr_din_w),
        .App_wr_dm         (App_wr_dm_w),
        .write_clk         (sd_card_clk),
        .write_req         (sd_wr_req),
        .write_req_ack     (sd_wr_ack),
        .write_finish      (frame_write_finish),
        .write_addr_0      (BUF0_ADDR),
        .write_addr_1      (BUF1_ADDR),
        .write_addr_2      (24'd0),
        .write_addr_3      (24'd0),
        .write_addr_index  (write_buf_idx),
        .write_len         (FRAME_PIXELS),
        .write_en          (sd_wr_en),
        .write_data        (sd_wr_data)
    );

    // ---- 视频时序（产生读请求 + 行列同步）----
    video_timing_data U_vtiming (
        .video_clk    (video_clk),
        .rst          (rst_all),
        .read_req     (vread_req),
        .read_req_ack (vread_ack),
        .hs           (hs_0),
        .vs           (vs_0),
        .de           (de_0)
    );

    // ---- 从帧缓存读出像素，附同步信号 ----
    video_delay #(.DATA_WIDTH(24)) U_vdelay (
        .video_clk (video_clk),
        .rst       (rst_all),
        .read_en   (vread_en),
        .read_data (vread_data[31:8]),   // RGB 在高 24 位
        .hs        (hs_0),
        .vs        (vs_0),
        .de        (de_0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout_data_raw)
    );

    // 首帧提交前显示黑，之后显示帧缓存内容
    assign vout_data = display_valid ? vout_data_raw : 24'd0;

    // ---- RGB → AXI-stream ----
    wire s_user, s_valid, s_last, s_ready;
    wire [23:0] s_data;
    video_rgb_to_axis_640x480 U_rgb2axis (
        .I_clk        (video_clk),
        .I_rst        (rst_all),
        .I_vs         (vs),
        .I_de         (de),
        .I_rgb        (vout_data),
        .O_video_user (s_user),
        .O_video_valid(s_valid),
        .O_video_last (s_last),
        .O_video_data (s_data)
    );

    // ---- HDMI 发送 core（640×480，外部数据）----
    wire [9:0] ch0_tmds, ch1_tmds, ch2_tmds, clk_tmds;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"), .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(125)
    ) U_hdmi_core (
        .I_pixel_clk        (video_clk),
        .I_rst              (rst_all),
        .I_edid_read_trig   (1'b0),
        .O_edid_read_valid  (),
        .O_edid_read_data   (),
        .I_axis_s_user      (s_user),
        .I_axis_s_valid     (s_valid),
        .I_axis_s_last      (s_last),
        .I_axis_s_data      (s_data),
        .O_axis_s_ready     (s_ready),
        .I_audio_valid      (1'b0),
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),
        .I_acr_valid        (1'b0),
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd0),
        .O_video_locked     (),
        .O_ddc_scl          (),
        .IO_ddc_sda         (),
        .O_ch0_tmds_data    (ch0_tmds),
        .O_ch1_tmds_data    (ch1_tmds),
        .O_ch2_tmds_data    (ch2_tmds),
        .O_clk_tmds_data    (clk_tmds)
    );

    // ---- 官方 PHY ----
    hdmi_phy_wrapper #(.DEVICE("EG")) U_phy (
        .I_pixel_clk        (video_clk),
        .I_serial_clk       (hdmi_5x_clk),
        .I_rst              (rst_all),
        .I_tmds_channel_0   (ch0_tmds),
        .I_tmds_channel_1   (ch1_tmds),
        .I_tmds_channel_2   (ch2_tmds),
        .I_tmds_channel_clk (clk_tmds),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

endmodule
