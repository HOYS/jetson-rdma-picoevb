# Constraints for the SQRL Acorn CLE-215+ (XC7A200T-3FBG484). The CLE-215+
# shares its PCB with the RHS Research NiteFury; pin assignments are taken from
# https://github.com/RHSResearchLLC/NiteFury-and-LiteFury.

set_property PACKAGE_PIN J1 [get_ports perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports perst_n]
set_property PULLUP true [get_ports perst_n]
set_false_path -from [get_ports perst_n]

set_property PACKAGE_PIN G1 [get_ports clkreq_n]
set_property IOSTANDARD LVCMOS33 [get_ports clkreq_n]

set_property PACKAGE_PIN F6 [get_ports refclk_p]
set_property PACKAGE_PIN E6 [get_ports refclk_n]
create_clock -period 10.000 -name sys_clk [get_ports refclk_p]

# The PCIe lane placement is in acorn-cle215-early.xdc.

# The link watchdog runs from the configuration oscillator (65 MHz +/-50%),
# asynchronous to everything else; its reset output feeds the PCIe core's
# asynchronous sys_rst_n.
create_clock -period 10.000 -name cfgmclk [get_pins link_watchdog/startup/CFGMCLK]
set_clock_groups -asynchronous -group [get_clocks cfgmclk]

# Active-low user LEDs
set_property PACKAGE_PIN G3 [get_ports {leds[0]}]
set_property PACKAGE_PIN H3 [get_ports {leds[1]}]
set_property PACKAGE_PIN G4 [get_ports {leds[2]}]
set_property PACKAGE_PIN H4 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[*]}]
set_property PULLUP true [get_ports {leds[*]}]
set_property DRIVE 8 [get_ports {leds[*]}]

# 0..3 are the 4 FPGA I/Os on the P2 debug header
set_property PACKAGE_PIN H5 [get_ports iocon[0]]
set_property PACKAGE_PIN J5 [get_ports iocon[1]]
set_property PACKAGE_PIN J2 [get_ports iocon[2]]
set_property PACKAGE_PIN K2 [get_ports iocon[3]]
set_property IOSTANDARD LVCMOS33 [get_ports {iocon[*]}]

# Boot from the on-board S25FL256S QSPI flash, clocked by the board's 90 MHz
# oscillator on EMCCLK rather than the internal ~33 MHz CCLK, so that the
# FPGA is configured in time for the host's PCIe link training at power-on
# (otherwise the link may train as x1, or not at all).
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN Div-1 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPPOWERDOWN ENABLE [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
