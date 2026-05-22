include ../../Makefile.common

# Static baud bitstream. Usage: make compile-baud BAUD=57600
# BAUD options: 115200 (div=434), 57600 (div=868), 38400 (div=1302), 9600 (div=5208)
BAUD     ?= 115200
BAUD_DIV  = $(shell python3 -c "print(round(50000000/$(BAUD)))")

compile-baud:
	@echo "=== Static baud bitstream: $(BAUD) baud (BAUD_DIV=$(BAUD_DIV)) ==="
	@test -f build/rtl/soc_top.sv || (echo "Run 'make gen' first" && false)
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV($(BAUD_DIV))/' build/rtl/soc_top.sv
	$(MAKE) compile
	cp output_files/soc_top.sof output_files/soc_top_$(BAUD)baud.sof
	@echo "=== Restoring default 115200 baud ==="
	sed -i 's/UART_DEFAULT_BAUD_DIV([0-9]*)/UART_DEFAULT_BAUD_DIV(434)/' build/rtl/soc_top.sv
	@echo "=== Done: output_files/soc_top_$(BAUD)baud.sof ==="

compile-all-bauds: compile-baud-115200 compile-baud-57600 compile-baud-38400 compile-baud-9600

compile-baud-115200:
	$(MAKE) compile-baud BAUD=115200

compile-baud-57600:
	$(MAKE) compile-baud BAUD=57600

compile-baud-38400:
	$(MAKE) compile-baud BAUD=38400

compile-baud-9600:
	$(MAKE) compile-baud BAUD=9600
