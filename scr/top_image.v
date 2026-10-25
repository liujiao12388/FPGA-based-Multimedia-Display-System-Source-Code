//==========================================================================
// 模块：top_image —— TF卡(固定扇区直读) → SDRAM帧缓存 → HDMI 显示
//--------------------------------------------------------------------------
// 自研部分：sd_spi_driver（SD驱动）、image_loader（读图写帧）；
//           图片格式为自定义“裸RGBX”（无FAT32、无BMP头）。
// 复用部分：SDRAM控制器、帧缓存、HDMI core/PHY（核心难点件）。
// 顶层连线：自写。
//==========================================================================
module top_image (
    input  wire clk,          // 板载 50MHz（K14）
    input  wire rst_n,        // 复位（H14）

    // SD 卡（SPI 模式）
    output wire SD_CLK,       // M2
    output wire SD_MOSI,      // L3
    input  wire SD_MISO,      // K6
    output wire SD_CS,        // R2

    // 按键
    input  wire KEY0,         // F7 手动切下一张
    input  wire KEY1,         // E7 启停自动轮播

    // HDMI
    output wire HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P,

    // 诊断 LED（板载 LED0~LED3）
    output wire LED0,   // SD 初始化完成 = 亮
    output wire LED1,   // 开始读扇区 = 亮
    output wire LED2,   // 整帧加载完成 = 亮
    output wire LED3    // 出错(sd_err) = 亮
);
    localparam MEM_DATA_BITS=32, ADDR_BITS=21;
    localparam FRAME_PIXELS = 24'd307200;
    localparam BUF0_ADDR=24'd0, BUF1_ADDR=24'd307200;

    //---- 时钟/复位 ----
    wire sys_pll_lock, video_pll_lock;
    wire sd_card_clk, ext_mem_clk, ext_mem_clk_sft;
    wire video_clk, hdmi_5x_clk;
    wire rst_all;

    reg [19:0] rst_cnt=0; reg rst_all_reg=1'b1;
    always @(posedge clk) begin
        if (!rst_n) begin rst_cnt<=0; rst_all_reg<=1'b1; end
        else if (!rst_all_reg) rst_all_reg<=1'b0;
        else if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt<20'd1_000_000) begin rst_cnt<=rst_cnt+1; rst_all_reg<=1'b1; end
            else rst_all_reg<=1'b0;
        end else begin rst_cnt<=0; rst_all_reg<=1'b1; end
    end
    assign rst_all = rst_all_reg;

    sys_pll U_sys_pll (.refclk(clk), .reset(1'b0), .extlock(sys_pll_lock),
        .clk0_out(sd_card_clk), .clk1_out(ext_mem_clk), .clk2_out(ext_mem_clk_sft));
    video_pll U_video_pll (.refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
        .clk0_out(video_clk), .clk1_out(hdmi_5x_clk));

    //---- SD 驱动 ----
    wire sd_start, sd_init_done, sd_done, sd_rd_valid, sd_err;
    wire [3:0]  sd_dbg;
    wire [31:0] sd_sector;
    wire [7:0]  sd_rd_data;
    wire spi_clk_w, spi_cs_n_w, spi_mosi_w;

    sd_spi_driver U_sd (
        .clk(sd_card_clk), .rst(rst_all),
        .start(sd_start), .sector(sd_sector),
        .spi_clk(spi_clk_w), .spi_cs_n(spi_cs_n_w), .spi_mosi(spi_mosi_w), .spi_miso(SD_MISO),
        .rd_data(sd_rd_data), .rd_valid(sd_rd_valid),
        .init_done(sd_init_done), .done(sd_done), .err(sd_err),
        .dbg(sd_dbg)
    );
    assign SD_CLK = spi_clk_w;
    assign SD_CS  = spi_cs_n_w;
    assign SD_MOSI= spi_mosi_w;

    //---- 按键消抖（自研）----
    wire key_next, key_auto;
    key_debounce #(.CNT_MAX(20'd500_000)) U_key_next (
        .clk(sd_card_clk), .rst(rst_all), .key_in(KEY0), .key_press(key_next));
    key_debounce #(.CNT_MAX(20'd500_000)) U_key_auto (
        .clk(sd_card_clk), .rst(rst_all), .key_in(KEY1), .key_press(key_auto));

    //---- 图像加载器相关信号（提前声明）----
    wire        fb_wr_req, fb_wr_en;
    wire [31:0] fb_wr_data;
    wire        fb_wr_ack;
    wire        load_done;
    wire        ld_busy;

    //---- 轮播/切换状态机（自研）----
    localparam IMG_COUNT = 3'd4;          // 卡上放的图片张数
    wire        load_start;
    wire [1:0]  load_idx, cur_idx;
    wire        auto_play;
    slideshow_ctrl #(.PERIOD(32'd300_000_000)) U_slide (
        .clk(sd_card_clk), .rst(rst_all),
        .key_next(key_next), .key_auto(key_auto),
        .ready(sd_init_done),
        .img_count(IMG_COUNT),
        .load_done(load_done),
        .load_start(load_start), .load_idx(load_idx),
        .img_idx(cur_idx), .auto_play(auto_play)
    );

    //---- 图像加载器（可切图）----
    image_loader #(.IMG_BASE(32'd2049), .SECT_PER_IMG(32'd1801)) U_loader (
        .clk(sd_card_clk), .rst(rst_all),
        .start(load_start), .start_idx(load_idx), .load_done(load_done),
        .sd_start(sd_start), .sd_sector(sd_sector),
        .sd_init_done(sd_init_done),
        .sd_rd_data(sd_rd_data), .sd_rd_valid(sd_rd_valid), .sd_done(sd_done),
        .wr_req(fb_wr_req), .wr_req_ack(fb_wr_ack),
        .wr_en(fb_wr_en), .wr_data(fb_wr_data),
        .busy(ld_busy)
    );

    //---- 图像显示的“有效”信号：首次加载完成后拉高 ----
    // 注意：load_done 是 100MHz 域的单周期脉冲，若在 25MHz 视频域去捕会被漏掉。
    //       故 image_valid 在 sd_card_clk 域置位（同域可靠），其输出是稳定电平，
    //       跨到视频域使用没有问题。
    reg image_valid;
    always @(posedge sd_card_clk or posedge rst_all)
        if (rst_all) image_valid<=1'b0;
        else if (load_done) image_valid<=1'b1;

    //---- SDRAM 接口 ----
    wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
    wire App_wr_en, App_rd_en, Sdr_rd_en;
    wire [ADDR_BITS-1:0]     App_wr_addr, App_rd_addr;
    wire [MEM_DATA_BITS-1:0] App_wr_din, Sdr_rd_dout;
    wire [3:0] App_wr_dm;

    sdram U_sdram (
        .Clk(ext_mem_clk), .Clk_sft(ext_mem_clk_sft), .Rst(rst_all),
        .Sdr_init_done(Sdr_init_done), .Sdr_init_ref_vld(Sdr_init_ref_vld), .Sdr_busy(Sdr_busy),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_dm(App_wr_dm), .App_wr_din(App_wr_din),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout)
    );

    //---- 帧缓存读写 ----
    wire        vread_req, vread_ack, vread_en;
    wire [31:0] vread_data;

    frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(640), .FRAME_HEIGHT(480)) U_frame (
        .mem_clk(ext_mem_clk), .rst(rst_all),
        .Sdr_init_done(Sdr_init_done), .Sdr_init_ref_vld(Sdr_init_ref_vld), .Sdr_busy(Sdr_busy),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr), .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(video_clk), .read_req(vread_req), .read_req_ack(vread_ack), .read_finish(),
        .read_addr_0(BUF0_ADDR), .read_addr_1(BUF1_ADDR), .read_addr_2(24'd0), .read_addr_3(24'd0),
        .read_addr_index(2'd0), .read_len(FRAME_PIXELS), .read_en(vread_en), .read_data(vread_data),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .write_clk(sd_card_clk), .write_req(fb_wr_req), .write_req_ack(fb_wr_ack), .write_finish(),
        .write_addr_0(BUF0_ADDR), .write_addr_1(BUF1_ADDR), .write_addr_2(24'd0), .write_addr_3(24'd0),
        .write_addr_index(2'd0), .write_len(FRAME_PIXELS), .write_en(fb_wr_en), .write_data(fb_wr_data)
    );

    //---- 视频时序 + 读出 ----
    wire hs_0, vs_0, de_0, hs_d, vs_d, de_d;
    wire [23:0] vout_raw, vout_data;

    video_timing_data U_vtiming (
        .video_clk(video_clk), .rst(rst_all),
        .read_req(vread_req), .read_req_ack(vread_ack),
        .hs(hs_0), .vs(vs_0), .de(de_0)
    );
    video_delay #(.DATA_WIDTH(24)) U_vdelay (
        .video_clk(video_clk), .rst(rst_all),
        .read_en(vread_en), .read_data(vread_data[31:8]),
        .hs(hs_0), .vs(vs_0), .de(de_0),
        .hs_r(hs_d), .vs_r(vs_d), .de_r(de_d), .vout_data(vout_raw)
    );

    // 注：vout_data 的选择逻辑放在文件末尾统一处理（图片 or 状态色）

    //---- RGB → AXI → HDMI ----
    wire s_user, s_valid, s_last, s_ready;
    wire [23:0] s_data;
    video_rgb_to_axis_640x480 U_rgb2axis (
        .I_clk(video_clk), .I_rst(rst_all),
        .I_vs(vs_d), .I_de(de_d), .I_rgb(vout_data),
        .O_video_user(s_user), .O_video_valid(s_valid), .O_video_last(s_last), .O_video_data(s_data)
    );

    wire [9:0] ch0,ch1,ch2,chk;

    //---- 自研音频源 + ACR（交给 HDMI core 打包进消隐期）----
    wire        aud_valid;
    wire [23:0] aud_left, aud_right;
    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;
    tone_gen #(.CLK_HZ(25_000_000), .FS_HZ(48_000)) U_tone (
        .clk(video_clk), .rst(rst_all),
        .audio_valid(aud_valid), .audio_left(aud_left), .audio_right(aud_right)
    );
    audio_arc_calculate #(.ACR_N(6144)) U_acr (
        .I_clk(video_clk), .I_rst(rst_all), .I_audio_valid(aud_valid),
        .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n)
    );

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),.HTOTAL(800),.HSA(96),.HFP(16),.HBP(48),.HACTIVE(640),
        .VTOTAL(525),.VSA(2),.VFP(10),.VBP(33),.VACTIVE(480),
        .VIDEO_VIC(1),.VIDEO_TPG("Disable"),.VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(125)
    ) U_core (
        .I_pixel_clk(video_clk),.I_rst(rst_all),.I_edid_read_trig(1'b0),
        .O_edid_read_valid(),.O_edid_read_data(),
        .I_axis_s_user(s_user),.I_axis_s_valid(s_valid),.I_axis_s_last(s_last),.I_axis_s_data(s_data),
        .O_axis_s_ready(s_ready),
        .I_audio_valid(aud_valid),.I_audio_left_data(aud_left),.I_audio_right_data(aud_right),
        .I_acr_valid(acr_valid),.I_acr_cts(acr_cts),.I_acr_n(acr_n),
        .O_video_locked(),.O_ddc_scl(),.IO_ddc_sda(),
        .O_ch0_tmds_data(ch0),.O_ch1_tmds_data(ch1),.O_ch2_tmds_data(ch2),.O_clk_tmds_data(chk)
    );
    hdmi_phy_wrapper #(.DEVICE("EG")) U_phy (
        .I_pixel_clk(video_clk),.I_serial_clk(hdmi_5x_clk),.I_rst(rst_all),
        .I_tmds_channel_0(ch0),.I_tmds_channel_1(ch1),.I_tmds_channel_2(ch2),.I_tmds_channel_clk(chk),
        .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P)
    );
    //---- 诊断 LED ----
    assign LED0 = sd_init_done;                    // D1: SD 初始化完成
    assign LED1 = auto_play;                       // D2: 自动轮播开启
    assign LED2 = image_valid;                     // D3: 已有图显示
    assign LED3 = sd_err;                          // D4: SD 出错

    //---- 状态颜色：读图未完成时，用纯色屏表示“卡在哪条 SD 命令”----
    wire [3:0] sd_dbg;                              // {err, 命令码}
    wire [2:0] dbg_op = sd_dbg[2:0];
    reg  [23:0] stat_color;
    always @(*) case (dbg_op)
        3'd0: stat_color = 24'hFF0000;   // 红  = 卡在 CMD0
        3'd1: stat_color = 24'h00FF00;   // 绿  = 卡在 CMD8
        3'd2: stat_color = 24'h0000FF;   // 蓝  = 卡在 CMD55
        3'd3: stat_color = 24'hFFFF00;   // 黄  = 卡在 ACMD41
        3'd4: stat_color = 24'h00FFFF;   // 青  = 卡在 CMD58
        3'd5: stat_color = 24'hFF00FF;   // 品红 = 卡在读扇区
        default: stat_color = 24'h808080;
    endcase
    // 优先显示图片；否则显示状态色
    //   白 = 正在读卡（若一直白 → 读卡卡住）
    //   灰 = 未在加载、也无图
    //   其他色 = 卡在某条 SD 初始化命令
    wire [23:0] status_screen = ld_busy ? 24'hFFFFFF :
                                (sd_init_done ? 24'h808080 : stat_color);
    assign vout_data = image_valid ? vout_raw : status_screen;

endmodule
