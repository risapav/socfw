# docs/05_DECISION_LOG.md — Decision Log

| ID | Date | Decision | Rationale |
|----|------|----------|-----------|
| D001 | 2026-06-21 | Project scope: sim only, no Quartus, no HW | Isolate AXI layer without synthesis variables |
| D002 | 2026-06-21 | RSHIFT=0, CMDREG=1 fixed (inherited from sdram_test_02/03) | Proven safe capture point |
| D003 | 2026-06-21 | Do not modify native_word_port.sv | Proven baseline from sdram_test_03; only the AXI adapter is under investigation |
| D004 | 2026-06-21 | board.yaml owned exclusively by user | Per CLAUDE.md rule, never touch board.yaml |
| D005 | 2026-06-21 | native_req_addr = axi_addr >> 1 (halfword base) | sdram_test_03 D006: native port uses halfword addresses; AXI uses byte addresses |
| D006 | 2026-06-21 | M1 uses fake native backend (no PHY/model) | Isolate AXI adapter behavior before adding real SDRAM path |
| D007 | 2026-06-21 | Protocol guards: WSTRB≠4'b1111 or AWADDR[1:0]≠00 → SLVERR, skip native | Adapter must not forward partial or misaligned writes to native port; 32-bit SDRAM accepts full words only |
| D008 | 2026-06-21 | Protocol guard evaluated at AW+W merge point (IDLE, AW_ONLY→W, W_ONLY→AW) | All three paths must check both addr alignment and wstrb before issuing native_req |
| D009 | 2026-06-21 | Early AXI BVALID accepted for current single-slave model (E005) | native_word_port serializes subsequent reads behind the active write via req_ready; ST_RD_ISSU stalls until NWP IDLE. Revisit only if adding multiple outstanding transactions, buffering, or independent masters. |
| D010 | 2026-06-21 | Close sdram_test_04 after M4 full-chain AXI backpressure PASS | AXI adapter, address conversion, protocol guards, immediate read-after-BVALID, multi-address, and BREADY/RREADY backpressure are all proven in simulation through the complete AXI->NWP->PHY->SDRAM chain (E001-E007). The original sdram_test_01 bug was not reproduced at the AXI adapter layer. Next layer is HW validation in sdram_test_05 (Quartus + BIST @125 MHz). |
