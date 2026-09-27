# zybo.xdc -- pin constraints for the TEMPO-32 emulation on the ORIGINAL Zybo.
# Only the 125 MHz board clock is pinned; everything else goes over JTAG
# (VIO/ILA). 125 MHz comes from the Ethernet PHY on pin L16 (Zybo Rev B
# reference manual, section 12 "Clock Sources").
set_property PACKAGE_PIN L16 [get_ports clk125_p]
set_property IOSTANDARD LVCMOS33 [get_ports clk125_p]
create_clock -period 8.000 -name clk125_in [get_ports clk125_p]
