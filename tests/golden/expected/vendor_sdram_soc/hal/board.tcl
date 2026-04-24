# AUTO-GENERATED - DO NOT EDIT
# Device family: Cyclone IV E
# Device part:   EP4CE55F23C8

set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE  EP4CE55F23C8

# RESET_N
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to RESET_N
set_location_assignment PIN_W13 -to RESET_N

# SYS_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to SYS_CLK
set_location_assignment PIN_T2 -to SYS_CLK

# ZS_ADDR
set_location_assignment PIN_T6 -to ZS_ADDR[0]
set_location_assignment PIN_R6 -to ZS_ADDR[1]
set_location_assignment PIN_R5 -to ZS_ADDR[2]
set_location_assignment PIN_P5 -to ZS_ADDR[3]
set_location_assignment PIN_P6 -to ZS_ADDR[4]
set_location_assignment PIN_V7 -to ZS_ADDR[5]
set_location_assignment PIN_V6 -to ZS_ADDR[6]
set_location_assignment PIN_U7 -to ZS_ADDR[7]
set_location_assignment PIN_U6 -to ZS_ADDR[8]
set_location_assignment PIN_N6 -to ZS_ADDR[9]
set_location_assignment PIN_N8 -to ZS_ADDR[10]
set_location_assignment PIN_P7 -to ZS_ADDR[11]
set_location_assignment PIN_P8 -to ZS_ADDR[12]

# ZS_BA
set_location_assignment PIN_N9 -to ZS_BA[0]
set_location_assignment PIN_P9 -to ZS_BA[1]

# ZS_CAS_N
set_location_assignment PIN_U1 -to ZS_CAS_N

# ZS_CKE
set_location_assignment PIN_V3 -to ZS_CKE

# ZS_CLK
set_location_assignment PIN_V4 -to ZS_CLK

# ZS_CS_N
set_location_assignment PIN_V2 -to ZS_CS_N

# ZS_DQ
set_location_assignment PIN_T10 -to ZS_DQ[0]
set_location_assignment PIN_T9 -to ZS_DQ[1]
set_location_assignment PIN_V10 -to ZS_DQ[2]
set_location_assignment PIN_V9 -to ZS_DQ[3]
set_location_assignment PIN_U9 -to ZS_DQ[4]
set_location_assignment PIN_U8 -to ZS_DQ[5]
set_location_assignment PIN_T8 -to ZS_DQ[6]
set_location_assignment PIN_T7 -to ZS_DQ[7]
set_location_assignment PIN_P3 -to ZS_DQ[8]
set_location_assignment PIN_P4 -to ZS_DQ[9]
set_location_assignment PIN_R2 -to ZS_DQ[10]
set_location_assignment PIN_R1 -to ZS_DQ[11]
set_location_assignment PIN_R4 -to ZS_DQ[12]
set_location_assignment PIN_R3 -to ZS_DQ[13]
set_location_assignment PIN_T5 -to ZS_DQ[14]
set_location_assignment PIN_T4 -to ZS_DQ[15]

# ZS_DQM
set_location_assignment PIN_V11 -to ZS_DQM[0]
set_location_assignment PIN_R0 -to ZS_DQM[1]

# ZS_RAS_N
set_location_assignment PIN_U2 -to ZS_RAS_N

# ZS_WE_N
set_location_assignment PIN_V1 -to ZS_WE_N
