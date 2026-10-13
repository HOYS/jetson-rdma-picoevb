# PCIe Gen2 x4. The M.2 lanes are not routed to the bank 216 MGTP channels in
# order (and lanes 0, 2 and 3 have P/N swapped, which PCIe corrects):
#   M.2 lane 0 = MGTP ch 2 = GTPE2_CHANNEL_X0Y6 (RX B10/A10, TX B6/A6)
#   M.2 lane 1 = MGTP ch 0 = GTPE2_CHANNEL_X0Y4 (RX B8/A8,   TX B4/A4)
#   M.2 lane 2 = MGTP ch 1 = GTPE2_CHANNEL_X0Y5 (RX D11/C11, TX D5/C5)
#   M.2 lane 3 = MGTP ch 3 = GTPE2_CHANNEL_X0Y7 (RX D9/C9,   TX D7/C7)
# The XDMA IP's own constraints place PCIe lanes 0-3 on X0Y7-X0Y4. Moving
# the lanes from there is a cyclic permutation that can't be done one LOC at a
# time, so this file is processed EARLY, before the IP's constraints: these
# placements take the sites first, and the IP's conflicting LOCs are rejected
# (with critical warnings, which are expected). A x1 or x2 slot also works,
# since lane 0 is correct.
set_property LOC GTPE2_CHANNEL_X0Y6 [get_cells -hierarchical -filter {NAME =~ *pipe_lane?0?.gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y4 [get_cells -hierarchical -filter {NAME =~ *pipe_lane?1?.gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y5 [get_cells -hierarchical -filter {NAME =~ *pipe_lane?2?.gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y7 [get_cells -hierarchical -filter {NAME =~ *pipe_lane?3?.gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property PACKAGE_PIN B10 [get_ports {per_p[0]}]
set_property PACKAGE_PIN A10 [get_ports {per_n[0]}]
set_property PACKAGE_PIN B6 [get_ports {pet_p[0]}]
set_property PACKAGE_PIN A6 [get_ports {pet_n[0]}]
set_property PACKAGE_PIN B8 [get_ports {per_p[1]}]
set_property PACKAGE_PIN A8 [get_ports {per_n[1]}]
set_property PACKAGE_PIN B4 [get_ports {pet_p[1]}]
set_property PACKAGE_PIN A4 [get_ports {pet_n[1]}]
set_property PACKAGE_PIN D11 [get_ports {per_p[2]}]
set_property PACKAGE_PIN C11 [get_ports {per_n[2]}]
set_property PACKAGE_PIN D5 [get_ports {pet_p[2]}]
set_property PACKAGE_PIN C5 [get_ports {pet_n[2]}]
set_property PACKAGE_PIN D9 [get_ports {per_p[3]}]
set_property PACKAGE_PIN C9 [get_ports {per_n[3]}]
set_property PACKAGE_PIN D7 [get_ports {pet_p[3]}]
set_property PACKAGE_PIN C7 [get_ports {pet_n[3]}]
