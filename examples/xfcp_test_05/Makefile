include ../../Makefile.common

CLOCK_HZ ?= 125000000
BAUD     ?= 115200
BAUD_DIV  = $(shell python3 -c "print(round($(CLOCK_HZ)/$(BAUD)))")

compile-baud:
	@echo "=== Static baud bitstream: $(BAUD) baud (BAUD_DIV=$(BAUD_DIV)) ==="
	@test -f build/rtl/soc_top.sv || (echo "Run 'make gen' first" && false)
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV($(BAUD_DIV))/' build/rtl/soc_top.sv
	$(MAKE) compile
	cp output_files/soc_top.sof output_files/soc_top_$(BAUD)baud.sof
	@echo "=== Restoring default baud ==="
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV(1085)/' build/rtl/soc_top.sv
	@echo "=== Done: output_files/soc_top_$(BAUD)baud.sof ==="
