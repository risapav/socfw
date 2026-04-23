# AUTO-GENERATED - DO NOT EDIT
# Device family: Cyclone IV E
# Device part:   EP4CE55F23C8

set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE  EP4CE55F23C8

# RESET_N
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to RESET_N
set_location_assignment PIN_W13 -to RESET_N

# SDRAM_ADDR
set_location_assignment PIN_T6 -to SDRAM_ADDR[0]
set_location_assignment PIN_R6 -to SDRAM_ADDR[1]
set_location_assignment PIN_R5 -to SDRAM_ADDR[2]
set_location_assignment PIN_P5 -to SDRAM_ADDR[3]
set_location_assignment PIN_P6 -to SDRAM_ADDR[4]
set_location_assignment PIN_V7 -to SDRAM_ADDR[5]
set_location_assignment PIN_V6 -to SDRAM_ADDR[6]
set_location_assignment PIN_U7 -to SDRAM_ADDR[7]
set_location_assignment PIN_U6 -to SDRAM_ADDR[8]
set_location_assignment PIN_N6 -to SDRAM_ADDR[9]
set_location_assignment PIN_N8 -to SDRAM_ADDR[10]
set_location_assignment PIN_P7 -to SDRAM_ADDR[11]
set_location_assignment PIN_P8 -to SDRAM_ADDR[12]

# SDRAM_BA
set_location_assignment PIN_N9 -to SDRAM_BA[0]
set_location_assignment PIN_P9 -to SDRAM_BA[1]

# SDRAM_CAS_N
set_location_assignment PIN_U1 -to SDRAM_CAS_N

# SDRAM_CKE
set_location_assignment PIN_V3 -to SDRAM_CKE

# SDRAM_CLK
set_location_assignment PIN_V4 -to SDRAM_CLK

# SDRAM_CS_N
set_location_assignment PIN_V2 -to SDRAM_CS_N

# SDRAM_DQ
set_location_assignment PIN_T10 -to SDRAM_DQ[0]
set_location_assignment PIN_T9 -to SDRAM_DQ[1]
set_location_assignment PIN_V10 -to SDRAM_DQ[2]
set_location_assignment PIN_V9 -to SDRAM_DQ[3]
set_location_assignment PIN_U9 -to SDRAM_DQ[4]
set_location_assignment PIN_U8 -to SDRAM_DQ[5]
set_location_assignment PIN_T8 -to SDRAM_DQ[6]
set_location_assignment PIN_T7 -to SDRAM_DQ[7]
set_location_assignment PIN_P3 -to SDRAM_DQ[8]
set_location_assignment PIN_P4 -to SDRAM_DQ[9]
set_location_assignment PIN_R2 -to SDRAM_DQ[10]
set_location_assignment PIN_R1 -to SDRAM_DQ[11]
set_location_assignment PIN_R4 -to SDRAM_DQ[12]
set_location_assignment PIN_R3 -to SDRAM_DQ[13]
set_location_assignment PIN_T5 -to SDRAM_DQ[14]
set_location_assignment PIN_T4 -to SDRAM_DQ[15]

# SDRAM_DQM
set_location_assignment PIN_V11 -to SDRAM_DQM[0]
set_location_assignment PIN_R0 -to SDRAM_DQM[1]

# SDRAM_RAS_N
set_location_assignment PIN_U2 -to SDRAM_RAS_N

# SDRAM_WE_N
set_location_assignment PIN_V1 -to SDRAM_WE_N

# SYS_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to SYS_CLK
set_location_assignment PIN_T2 -to SYS_CLK
