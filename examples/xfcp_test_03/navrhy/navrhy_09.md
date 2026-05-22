Áno, **Signal Tap debug sa dá použiť aj v Quartus Prime Lite/Standard 25.1**, vrátane verzie **25.1std**. Intel dokumentácia pre Quartus 25.1std priamo uvádza Signal Tap logic analyzer plugin a Intel opisuje Signal Tap ako nástroj dostupný v Quartus Prime na zachytávanie interných FPGA signálov cez JTAG bez potreby externých pinov. ([Intel][1])

Dôležité obmedzenie: v **Lite Edition** môže byť použitie Signal Tap časovo obmedzené. Jeden dokument k Intel Quartus Prime Lite explicitne uvádza, že pri Lite Edition existuje time limit na použitie Signal Tap Logic Analyzer. ([Totally Integrated Automation][2])

## Čo potrebuješ

Pre tvoju dosku a XFCP debug potrebuješ:

```text
1. Quartus Prime Lite/Standard 25.1
2. funkčný JTAG programátor, napr. USB-Blaster kompatibilný
3. voľné FPGA zdroje pre Signal Tap logiku
4. interný clock pre vzorkovanie, napr. SYS_CLK 50 MHz
5. recompiláciu projektu so Signal Tap inštanciou
```

Signal Tap používa internú FPGA logiku a pamäť na vzorky, takže zvýši spotrebu zdrojov. Pri tvojom projekte je to pravdepodobne v poriadku, pretože posledný build bol okolo 30 % logic elements.

## Pre XFCP by som sledoval tieto signály

Najprv by som nenahrával stovky signálov. Stačí úzky trace:

```text
UART RX / parser:
- uart_rx_valid
- uart_rx_data
- rx_fifo_valid
- rx_fifo_ready
- parser state
- parser_hdr_valid
- parser_wdata_valid
- parser_req_ready

Fabric:
- req_valid
- req_ready
- invalid_req
- dec_valid
- dec_sel
- req_hdr.opcode
- req_hdr.addr
- req_hdr.count
- ofifo_wvalid
- ofifo_rvalid
- ofifo_rdata.sel
- resp_start_pulse
- resp_type_q

Engine:
- eng_busy[0..5]
- eng_resp_done[0..5]
- eng_resp_type[selected]
- eng_error_timeout[selected]

Packetizer / TX:
- tx_start
- tx_valid
- tx_ready
- tx_data
- tx_done
- packetizer state
```

Trigger by som nastavil na problémové situácie:

```text
1. resp_start_pulse == 1
2. invalid_req == 1
3. eng_error_timeout != 0
4. parser_hdr_valid && !req_ready dlhšie než N taktov
5. tx_valid == 0 po prijatom requeste
```

## Najlepšia stratégia pre tvoj problém

Pre `0B response` by som spravil dva Signal Tap profily:

### Profil A — „request sa stratil“

Trigger:

```text
parser_hdr_valid == 1
```

Sleduj, či po ňom príde:

```text
req_valid/req_ready
ofifo_wvalid
eng_busy
eng_resp_done
resp_start_pulse
tx_valid
```

Ak `parser_hdr_valid` príde, ale `resp_start_pulse` nie, problém je vo fabric/engine.

### Profil B — „response sa nespustila“

Trigger:

```text
resp_start_pulse == 1
```

Sleduj:

```text
packetizer state
tx_valid
tx_data
uart_tx_valid/ready
```

Ak `resp_start_pulse` príde, ale `uart_tx` neposiela `0xFD`, problém je packetizer/TX cesta.

## Krátky záver

**Áno, v Quartus 25.1 Lite by si Signal Tap použiť mal vedieť**, ale rátaj s možným time-limit obmedzením Lite edície a s tým, že musíš mať JTAG pripojenie. Pre XFCP je Signal Tap veľmi vhodný, lebo ti presne ukáže, či sa transakcia stratí v parseri, fabrice, engine, packetizeri alebo UART TX.

[1]: https://www.intel.com/programmable/technical-pdfs/683593.pdf?utm_source=chatgpt.com "Quartus Prime Standard and Lite Editions: Version 25.1std ..."
[2]: https://docs.tia.siemens.cloud/r/simatic_s7_1500_et_200mp_manual_collection_eses_21/device-specific-information/technology-modules/creating-a-tm-fast-application/loading-a-tm-fast-application-onto-the-module/debugging-the-hello-world-user-logic-with-signal-tap-logic-analyzer/introduction-to-signal-tap-logic-analyzer?contentId=SIyYW4rxGzuUc0qxkONfzA&utm_source=chatgpt.com "Introduction to Signal Tap Logic Analyzer"
