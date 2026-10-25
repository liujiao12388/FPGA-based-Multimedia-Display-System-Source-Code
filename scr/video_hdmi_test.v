//==========================================================================
// 模块：video_hdmi_test —— 640×480 彩条 → HDMI（照赛题参考工程 lab_ex4_tf）
//--------------------------------------------------------------------------
// 组成（尽量用官方验证过的模块）：
//   video_pll                  —— 官方 PLL：50MHz → 25MHz(像素) + 125MHz(串行)
//   color_bar                  —— 官方时序/彩条源（产生 hs/vs/de/rgb，640×480）
//   video_rgb_to_axis_640x480  —— 官方 RGB→AXI-stream 转换
//   hdmi_1_4b_transmitter_core_wrapper —— 官方加密 HDMI core（VIDEO_TPG=Disable）
//   hdmi_phy_wrapper + lane_lvds_10_1  —— 官方 PHY（P-only 差分）
//
// 与 AC201 测试工程的差异：分辨率用 640×480（对齐赛题要求），
// 且 core 采用外部 AXI 数据（VIDEO_TPG="Disable"）。
//==========================================================================
module video_hdmi_test (
    input  wire clk,          // 板载 50MHz（K14）
    input  wire rst_n,        // 复位（H14，低有效）

    output wire HDMI_CLK_P,   // B10
    output wire HDMI_D0_P,    // D11
    output wire HDMI_D1_P,    // C11
    output wire HDMI_D2_P     // F10
);

    wire        pll_lock;
    wire        pixel_clk;    // 25MHz
    wire        serial_clk;   // 125MHz
    wire        rst;          // 高有效复位（照官方：~lock）

    wire        hs, vs, de;
    wire [7:0]  rgb_r, rgb_g, rgb_b;
    wire [23:0] rgb;

    wire        s_user, s_valid, s_last, s_ready;
    wire [23:0] s_data;

    wire [9:0]  ch0_tmds, ch1_tmds, ch2_tmds, clk_tmds;

    // ---- PLL（照官方：reset 接 0）----
    video_pll U_pll (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (pll_lock),
        .clk0_out(pixel_clk),    // 25MHz
        .clk1_out(serial_clk)    // 125MHz
    );

    assign rst = ~pll_lock;

    // ---- 官方时序/彩条源（640×480）----
    color_bar U_color_bar (
        .clk  (pixel_clk),
        .rst  (rst),
        .hs   (hs),
        .vs   (vs),
        .de   (de),
        .rgb_r(rgb_r),
        .rgb_g(rgb_g),
        .rgb_b(rgb_b)
    );

    assign rgb = {rgb_r, rgb_g, rgb_b};

    // ---- 官方 RGB → AXI-stream 转换 ----
    video_rgb_to_axis_640x480 U_rgb2axis (
        .I_clk        (pixel_clk),
        .I_rst        (rst),
        .I_vs         (vs),
        .I_de         (de),
        .I_rgb        (rgb),
        .O_video_user (s_user),
        .O_video_valid(s_valid),
        .O_video_last (s_last),
        .O_video_data (s_data)
    );

    // ---- 官方 HDMI core（640×480，外部数据）----
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"     ),
        .HTOTAL            (800      ),
        .HSA               (96       ),
        .HFP               (16       ),
        .HBP               (48       ),
        .HACTIVE           (640      ),
        .VTOTAL            (525      ),
        .VSA               (2        ),
        .VFP               (10       ),
        .VBP               (33       ),
        .VACTIVE           (480      ),
        .VIDEO_VIC         (1        ),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"    ),
        .AUDIO_SAMPLE_RATE ("48K"    ),
        .IIC_SCL_DIV       (125      )
    ) U_hdmi_core (
        .I_pixel_clk        (pixel_clk    ),
        .I_rst              (rst          ),
        .I_edid_read_trig   (1'b0         ),
        .O_edid_read_valid  (             ),
        .O_edid_read_data   (             ),
        .I_axis_s_user      (s_user       ),
        .I_axis_s_valid     (s_valid      ),
        .I_axis_s_last      (s_last       ),
        .I_axis_s_data      (s_data       ),
        .O_axis_s_ready     (s_ready      ),
        .I_audio_valid      (1'b0         ),
        .I_audio_left_data  (24'd0        ),
        .I_audio_right_data (24'd0        ),
        .I_acr_valid        (1'b0         ),
        .I_acr_cts          (20'd0        ),
        .I_acr_n            (20'd0        ),
        .O_video_locked     (             ),
        .O_ddc_scl          (             ),
        .IO_ddc_sda         (             ),
        .O_ch0_tmds_data    (ch0_tmds     ),
        .O_ch1_tmds_data    (ch1_tmds     ),
        .O_ch2_tmds_data    (ch2_tmds     ),
        .O_clk_tmds_data    (clk_tmds     )
    );

    // ---- 官方 PHY ----
    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) U_hdmi2phy_wrapper (
        .I_pixel_clk        (pixel_clk  ),
        .I_serial_clk       (serial_clk ),
        .I_rst              (rst        ),
        .I_tmds_channel_0   (ch0_tmds   ),
        .I_tmds_channel_1   (ch1_tmds   ),
        .I_tmds_channel_2   (ch2_tmds   ),
        .I_tmds_channel_clk (clk_tmds   ),
        .O_tmds_ch0_p       (HDMI_D0_P  ),
        .O_tmds_ch1_p       (HDMI_D1_P  ),
        .O_tmds_ch2_p       (HDMI_D2_P  ),
        .O_tmds_clk_p       (HDMI_CLK_P )
    );

endmodule
