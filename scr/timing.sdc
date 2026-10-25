# =========================================================================
# timing.sdc —— 时序约束（640×480 设计，参照赛题参考工程 lab_ex4_tf）
# =========================================================================

# 板载 50MHz 输入时钟
create_clock -name clk -period 20.000 -waveform {0 10.000} [get_ports {clk}]

# 自动推导 PLL 输出时钟（pixel_clk 25MHz / serial_clk 125MHz）
derive_clocks
