# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
# Derived from prog-flash.tcl in PicoEVB sample project, and the flash scripts
# in the NiteFury/LiteFury sample project.
#
# By default, connects to a JTAG cable (e.g. Xilinx Platform Cable USB II, or a
# Digilent JTAG-HS2/HS3) attached to this PC via a local hw_server. Set the
# environment variable XVC_URL (e.g. localhost:2542) to instead connect to a
# Xilinx Virtual Cable server such as xvcd.

# Connect to the HW
open_hw
for {set i 0} {$i < 10} {incr i} {
    if ([catch {
        # These commands can be unreliable, so retry them until it works.
        connect_hw_server
        if {[info exists ::env(XVC_URL)]} {
            open_hw_target -xvc_url $::env(XVC_URL)
        } else {
            open_hw_target
        }
    } errmsg]) {
        puts "Connection attempt $i failed: $errmsg
"
        if {$i != 9} {
            puts "Retrying connection attempt
";
            exec sleep 1
        }
        catch {
            close_hw_target
        } errmsg
        catch {
            disconnect_hw_server
        } errmsg
    } else {
        puts "Connection OK; continuing
"
        break
    }
}
if {$i == 10} {
    puts "Too many connection attempts; exiting
"
    exit 1
}

set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev == ""} {
    puts "No XC7A200T found on the JTAG chain; exiting
"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# Add flash part, s25fl256s; default to erase and program (no verify)
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}] 0]
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.ERASE  1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY  0 $cfgmem
set_property PROGRAM.CHECKSUM  0 $cfgmem
refresh_hw_device $dev
set_property PROGRAM.ADDRESS_RANGE  {use_file} $cfgmem
set_property PROGRAM.FILES [list "acorn-cle215.mcs"] $cfgmem
set_property PROGRAM.PRM_FILE {} $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

# Program the fabric with the flash loader
startgroup
if {![string equal         [get_property PROGRAM.HW_CFGMEM_TYPE $dev]         [get_property MEM_TYPE [get_property CFGMEM_PART $cfgmem]]] } {
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
}

# Program the flash
program_hw_cfgmem -hw_cfgmem $cfgmem
endgroup

# Reboot the FPGA from the newly programmed flash
boot_hw_device $dev

# Clean up and disconnect
close_hw_target
disconnect_hw_server
close_hw
