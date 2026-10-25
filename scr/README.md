# AC201 HDMI 最小复现工程 —— 使用说明

## 为什么做这个

我们之前自己重写的 HDMI 编码器在这块板上始终无信号。这个工程**不再用我们自己写的编码器**,而是**直接把官方 AC201 测试工程里验证过能出图的 HDMI 链路搬过来**。

搬用的文件（全部来自官方，未修改）：
- `hdmi_1_4b_transmitter_core_wrapper.enc.v` —— 官方加密 HDMI core（TMDS 编码 / 数据岛 / EDID）
- `pll_hdmi1_4b.v` —— 官方 PLL（50MHz → 73.33MHz 像素 + 366.67MHz 串行）
- `hdmi_phy_warpper.v` + `lane_lvds_10_1.v` —— 官方 PHY（ODDR 串行、P-only 差分）
- `video_source_test.v` —— 官方测试图源

自写的只有顶层 `video_hdmi_test.v`（把上面几个按官方 `design_top_wrapper.v` 的方式连起来）。

## 目标

先让它显示出官方那个测试图案。**只要它显示出来，就证明"官方链路搬到我们工程能用"**，然后我们再把视频源换成自己的图像。

## 在 TD 里操作

1. **新建工程**（或用你现有工程，但建议新建一个干净的）
   - 器件选 **EG4S20BG256**

2. **添加以下源文件**（都在本目录）：
   - `video_hdmi_test.v`          ← 顶层
   - `pll_hdmi1_4b.v`
   - `hdmi_1_4b_transmitter_core_wrapper.enc.v`
   - `hdmi_phy_warpper.v`
   - `lane_lvds_10_1.v`
   - `video_source_test.v`

3. **顶层模块** 设为 `video_hdmi_test`

4. **添加 IP**：把 `pll_hdmi1_4b.v` 作为 IP 加入（或直接用这个 .v）。
   同时把 `pll_hdmi1_4b.ipc` 放到工程的 `al_ip/` 下。

5. **添加约束**：
   - `IO.adc`（管脚）
   - `timing.sdc`（时序）
   （参考 `IO_official.adc` 是官方原约束）

6. **综合 → 布局布线 → 下载**

## 期望结果

显示器显示**官方测试图案**（彩色渐变条 / 测试画面），1280×720。

## 如果成功

下一步：把 `video_source_test` 换成我们能控制的图像源（接 AXI-stream 接口），再逐步接入 SDRAM 帧缓存和 TF 卡。

## 如果仍然无信号

那问题就**不在 HDMI 编码逻辑**（因为这条链路官方验证过），而在：
- 工程配置 / IP 生成方式
- 板子与我们的工程环境差异

到时候请告诉我，我再查工程配置层面。
