Zdieľané súbory tvoria komplexný a dobre štruktúrovaný hardvérový subsystém pre UART komunikáciu. Architektúra využíva moderné prístupy oddelenia riadiacej roviny (AXI-Lite) od dátovej roviny (AXI-Stream).

Tu je podrobná analýza funkčnosti jednotlivých vrstiev a modulov:

### 1. Centrálna Konfigurácia a Dátové Typy

Balíček `axi_pkg.sv` slúži ako centrálny bod pre definíciu parametrov a typov zberníc.

* Definuje základné parametre a dátové typy pre komunikáciu AXI4-Stream v celom projekte.


* Štandardná šírka dátovej zbernice (`TDATA`) je nastavená na 16 bitov.


* Šírka používateľského signálu (`TUSER`) je nastavená na 1 bit.


* Kód v balíčku obsahuje výhradne syntetizovateľné konštrukcie, plne kompatibilné s nástrojom Intel Quartus Prime.



---

### 2. AXI-Lite Riadiaca Rovina (Konfigurácia a Diagnostika)

Tieto moduly zabezpečujú prístup CPU/mikrokontroléra k stavovým a konfiguračným registrom.

**Generická banka registrov (`axil_regfile.sv`)**

* Modul poskytuje konfigurovateľnú banku registrov pre AXI-Lite zbernicu.


* Podporuje štyri typy správania registrov: `AXIL_RO` (iba na čítanie), `AXIL_RW` (čítanie/zápis), `AXIL_W1C` (zápis jednotky pre vymazanie) a `AXIL_PULSE` (zápis generuje 1-cyklový pulz).


* Chráni zbernicu pred zlyhaním tým, že pri čítaní mimo platného rozsahu adries vráti hodnotu `32'h0` a bezchybný stav `AXI_RESP_OKAY`.



**UART Adaptér (`axil_uart_adapter.sv`)**

* Funguje ako diagnostický a konfiguračný AXI-Lite adaptér pre UART komunikáciu.


* Mapuje registre podľa špecifických offsetov, kde `0x00` obsahuje konštantu `0x55415254` (ASCII pre "UART") a `0x04` slúži pre nastavenie preddeličky Baudovej rýchlosti.


* Udržuje diagnostické informácie (overrun, frame error, parity error) prostredníctvom "sticky" bitov v registri `STATUS`, ktoré sa vymažú jedine poslaním pulzu na register `ERR_CLR`.



**Všeobecný výstupný register (`axil_regs.sv`)**

* Slúži ako AXI-Lite modul pre riadenie generického výstupného registra.


* Podporuje maskovanie zápisu pomocou poľa `WSTRB`, čo umožňuje aktualizáciu iba vybraných bajtov v 32-bitovom slove.



---

### 3. AXI-Stream Dátová Rovina a FIFO Buffering

Tieto moduly transformujú prúdové dáta (streaming) na UART rámce a naopak.

| Modul | Popis a Funkcionalita |
| --- | --- |
| **`axis_uart_tx.sv`** | Zapuzdruje TX jadro a prijíma dáta na vysielanie cez rozhranie AXI-Stream Slave. Resetuje interný čítač pripulze označujúcom nové dáta, aby štart bit začal okamžite.

 |
| **`axis_uart_rx.sv`** | Zapuzdruje RX jadro pre príjem dát a poskytuje rozhranie AXI-Stream Master. Dokáže generovať signál `TLAST` s každým prijatým bajtom alebo bežať v čistom streamovacom režime bez `TLAST`.

 |
| **`axis_fifo_sync.sv`** | Slúži ako synchrónna vyrovnávacia pamäť optimalizovaná pre FPGA Block RAM. Poskytuje možnosť zapnúť režim FWFT (First-Word Fall-Through) pre prístup k prvým dátam bez oneskorenia a obsahuje bypass logiku pre nulovú latenciu pri prázdnom FIFO.

 |

---

### 4. Nízkoúrovňové UART Jadro (PHY)

Samotná hardvérová implementácia sériového protokolu.

*
**Top Modul (`uart.sv`):** Integrácia prijímacieho jadra, vysielacieho jadra a dvoch baudrate generátorov do jedného celku.


*
**Baud Generátor (`uart_baud_gen.sv`):** Generuje tri dôležité udalosti počas bitovej periódy – na začiatku, v strede (pre bezpečné vzorkovanie RX) a na konci periódy. Pre prijímač umožňuje synchronizáciu fázy na stred štartovacieho bitu.


*
**RX Jadro (`uart_core_rx.sv`):** Prijímač implementovaný ako Moore FSM optimalizovaný pre minimálnu latenciu. Zodpovedá za detekciu chýb rámca, parity a pretečenia. Zabezpečuje, že potvrdzovací signál `valid_o` je aktívny presne po prijatí posledného stop bitu.

Analýza funkčnosti je rozdelená hierarchicky od najnižšej fyzickej vrstvy (PHY) smerom nahor k transportnej (AXI-Stream) a riadiacej (AXI-Lite) vrstve. Architektúra vykazuje vysokú úroveň robustnosti a je navrhnutá s ohľadom na nízku latenciu a bezpečné prepojenie domén.

Tu je podrobné preverenie jednotlivých blokov:

### 1. Fyzická vrstva (PHY) – Nízkoúrovňové jadro UART

Tieto moduly pracujú priamo s fyzickými pinmi (`rxd_i`, `txd_o`) a presným časovaním.

* **`uart_baud_gen.sv` (Baud Generátor):**
* **Funkčnosť:** Namiesto klasického generovania jedného tiku (clock enable) vytvára tri nezávislé udalosti: `start_tick_o`, `half_tick_o` a `end_tick_o`.
* **Zhodnotenie:** Tento prístup je výborný. Výpočet `half_offset` (stred bitu) je kritický pre RX jadro, aby vzorkovalo prichádzajúci signál presne v jeho strede, čím sa eliminuje vplyv šumu a jitteru na hranách. Pulz `start_i` resetuje čítač – to je kľúčové pre fázovú synchronizáciu (Phase Align) prijímača pri detekcii štart bitu.


* **`uart_core_rx.sv` (Prijímacie jadro):**
* **Funkčnosť:** Implementované ako plne synchrónny Moore FSM. Na vzorkovanie vstupného signálu využíva dvojstupňový synchronizátor `{rxd_reg_1, rxd_reg_0}`.
* **Zhodnotenie:** Synchronizátor zabraňuje metastabilite z externého asynchrónneho vstupu. Extrakcia dát (`cfg_i.dbits`) je kombinačná a posiela dáta priamo na výstup so "zero-latency" potvrdením `valid_o` presne po poslednom stop bite. FSM ošetruje "false start" (ak úroveň štart bitu nevydrží do polovice periódy, vráti sa do IDLE).


* **`uart.sv` (Top-level PHY):**
* Spoľahlivo prepája inštancie RX, TX a ich príslušné baudrate generátory. Parametrizácia rešpektuje odovzdávanie `uart_conf_t` do submodulov.



---

### 2. Dátová vrstva (Transport) – AXI-Stream

Tieto moduly premosťujú asynchrónne/sériové dáta z PHY vrstvy do štandardizovaného toku.

* **`axis_uart_rx.sv` a `axis_uart_tx.sv` (AXI-Stream Wrappery):**
* **Funkčnosť:** Mapujú signály nízkoúrovňových jadier (`valid`, `ready`, `data`) na AXI-Stream handshake (`TVALID`, `TREADY`, `TDATA`).
* **Zhodnotenie:** Priradenie `TLAST` parametrom `AXIS_TLAST` v prijímači je užitočné (umožňuje posielať bajt po bajte, alebo tvoriť väčšie bloky). Výbornou črtou je generovanie/konzumovanie pulzov `rx_start_pulse` a `tx_start_pulse`, čím nadradený blok presne vie riadiť baudrate generátory bez blokovania zbernice.


* **`axis_fifo_sync.sv` (Synchrónny buffer):**
* **Funkčnosť:** Ukladá dáta medzi rýchlymi AXI doménami. Podporuje režim FWFT (First-Word Fall-Through).
* **Zhodnotenie:** Využíva pamäť typu rozhrania BRAM (Block RAM). Všimnite si podmienku `assign m_axis.TDATA = (USE_FWFT) ? (is_empty ? s_axis.TDATA : mem[...]) : ...`. Toto predstavuje kombinačný bypass z `s_axis` rovno do `m_axis` s nulovou latenciou.
* *Upozornenie:* FWFT kombinačný bypass je skvelý pre výkon (0-cyklové oneskorenie), no pre veľmi vysoké frekvencie v Quartuse môže vytvoriť dlhú kritickú cestu. Ak nastanú problémy s časovaním (setup time violations), odporúčam prepnúť `USE_FWFT` na `0`.



---

### 3. Riadiaca vrstva – AXI-Lite

Umožňuje procesoru konfigurovať UART a čítať jeho diagnostiku.

* **`axil_regfile.sv` (Centrálna banka registrov):**
* **Funkčnosť:** Abstrahuje AXI-Lite handshake od aplikačnej logiky. Využíva polia `REG_TYPES` pre definíciu správania každého registra.
* **Zhodnotenie:** Výborný návrhový vzor. Podpora rôznych typov `AXIL_W1C` (Write-1-to-Clear) a `AXIL_PULSE` odbremeňuje ostatné moduly od zložitej logiky na detekciu hrán pri zápise zo softvéru. Navyše obsahuje podporu pre `WSTRB` (byte strobes), čo zabraňuje prepisaniu nesúvisiacich bajtov.


* **`axil_uart_adapter.sv` (Diagnostický adaptér):**
* **Funkčnosť:** Obsahuje mapu konfiguračných (`BAUD_DIV`, `CONFIG`) a diagnostických registrov. Chytá chyby (frame, parity, overrun) z UART jadra.
* **Zhodnotenie:** Logika akumulácie (tzv. sticky bits) chýb z PHY je navrhnutá bezpečne. PHY pošle 1-taktový pulz chyby, adaptér si ho uloží do `overrun_r`, atď. Vďaka prepojeniu na `ERR_CLR` (pulzný register typu `AXIL_PULSE`) môže CPU tieto chyby cielene mazať bez rizika, že by prepísalo práve prichádzajúcu novú chybu.



---

### Potenciálny integračný konflikt (Na zváženie)

Moduly samostatne fungujú bezchybne, no pri ich integrácii si treba dať pozor na jednu špecifikáciu šírok:

1. V `axi_pkg.sv` je centrálne definované: `localparam int AXI_TDATA_WIDTH = 16;`. Týmto typom sa riadia všetky rozhrania `axi4s_payload_t`.
2. Avšak `axis_uart_rx.sv` a `tx` pracujú na základe parametra `DATA_WIDTH = 8`. Priradenie `assign m_axis.TDATA = core_data;` kde `m_axis.TDATA` má 16 bitov, ale `core_data` len 8 bitov, spôsobí tzv. implicit zero-extension (horné bajty sa vyplnia nulami). Pre Intel Quartus Prime to nie je fatálna chyba (nástroj priradí logickú nulu bez problému), ale linter (ako svlint/verilator) na to môže upozorniť. Odporúčam explicitne priradiť horné bity na nulu alebo využiť castovanie na presnú šírku.

Z pohľadu štruktúry a RTL pravidiel sú moduly napísané exkluzívne syntetizovateľnými konštrukciami a dodržujú moderné štandardy návrhu hardvéru.

Mám prejsť k overeniu špecifickej kritickej cesty (napríklad AXI handshake stavových automatov), alebo sa zamerať na niečo iné?

Pristúpme k detailnej verifikácii kritických ciest a "handshake" mechanizmov. Pri návrhu pre platformy ako Intel Quartus Prime je kľúčové zabezpečiť nielen logickú správnosť (FSM prechody), ale aj dodržiavanie štandardov zberníc (AMBA AXI) a zamedzenie vzniku príliš dlhých kombinačných ciest.

Tu je hĺbková analýza kritických AXI ciest a časovania vo vašich moduloch:

### 1. AXI-Lite Handshake (Modul `axil_regfile.sv`)

Implementácia zbernice AXI-Lite pre zápis a čítanie registrov je navrhnutá mimoriadne robustne a predchádza "deadlock" stavom.

* **Nezávislosť kanálov (Write Path):** Modul správne oddeľuje adresný kanál (`AWVALID`) a dátový kanál (`WVALID`). Využíva stavové registre `aw_pend_r` a `w_pend_r` na zachytenie adries a dát nezávisle od toho, v akom poradí dorazia.


*
**Kritická cesta zápisu:** K samotnému zápisu do registra (`wr_fire_w`) dôjde až vtedy, keď sú oba registre platné (`aw_pend_r & w_pend_r & ~b_valid_r`). Následne sa v ďalšom takte odošle odpoveď `b_valid_r`. Tento prístup je plne v súlade so špecifikáciou a je bezpečný pre syntézu.


* **Latencia čítania (Read Path):** Kanál pre čítanie má fixnú latenciu 1 hodinový takt. Po prijatí `ARVALID` sa asertuje `r_valid_r` a výstup sa registruje. Z pohľadu Quartus Prime to výborne rozdeľuje kritickú cestu a umožňuje dosiahnuť vysokú frekvenciu (Fmax).



---

### 2. Identifikovaný AXI-Stream Protokolový Konflikt (Modul `axis_uart_rx.sv`)

Pri analýze prepojenia jadra `uart_core_rx.sv` na štandard AXI-Stream sa nachádza kritický bod, ktorý formálne porušuje špecifikáciu AMBA AXI-Stream, hoci hardvérovo (na úrovni signálov) bude za určitých podmienok fungovať.

*
**Príčina (1-taktový pulz):** V module `uart_core_rx.sv` je signál `valid_o` definovaný kombinačne: `valid_o = (state_q == UART_STOP) && end_tick_i && (stop_cnt_q == 2'd1);`. Signál `end_tick_i` prichádza z baud generátora a trvá presne 1 takt. To znamená, že `valid_o` je aktívny vždy presne 1 hodinový cyklus.


*
**Protokolové mapovanie:** Vo wrapperi `axis_uart_rx.sv` je tento signál priamo priradený na zbernicu: `assign m_axis.TVALID = core_valid;`.


* **Porušenie štandardu:** Špecifikácia AXI-Stream striktne vyžaduje, že ak Master asertuje `TVALID`, **nesmie tento signál zhodiť (deasertovať)**, kým Slave nepotvrdí príjem asertovaním `TREADY`.
* **Dôsledok (Overrun):** Ak by nadradený modul (napr. FIFO) nemal miesto a poslal by `TREADY = 0`, pulz `TVALID` by jednoducho po jednom takte zmizol. Jadro UART to deteguje a správne nastaví `overrun_err_q`, ale prichádzajúci bajt sa stratí a AXI zbernica nedostane platný prenos.


* **Odporúčanie pre nápravu:** Zbernica `axis_uart_rx` by mala obsahovať tzv. "Skid Buffer" (registračný stupeň), ktorý podrží hodnoty `TDATA` a `TVALID` dovtedy, kým nepríde `TREADY = 1`.

---

### 3. FWFT Bypass a Kombinačná Cesta (Modul `axis_fifo_sync.sv`)

Dizajn FIFO buffera obsahuje voliteľný režim First-Word Fall-Through (FWFT) `USE_FWFT`, ktorý priamo ovplyvňuje kritické cesty (Critical Paths) počas syntézy a routovania.

* **Bypass logika (Nulová latencia):** Keď je `USE_FWFT = 1` a FIFO je prázdne, dáta z prichádzajúceho AXI-Stream rozhrania (`s_axis`) sa priamo asynchronne (kombinačne) preklápajú na výstup (`m_axis`). Je to vidieť v logike: `assign m_axis.TDATA = (USE_FWFT) ? (is_empty ? s_axis.TDATA : mem[rd_ptr_q[ADDR_WIDTH-1:0]]) [cite_start]: data_out_q;`. Rovnako je na tom signál `TVALID`.


* **Dopad na Intel Quartus Prime:** Z hľadiska RTL je to úplne korektné. Avšak prenos `s_axis -> m_axis` je čisto kombinačný. Ak je k vstupu FIFO pripojená dlhá kombinačná logika a na výstup ďalšia dlhá kombinačná logika, tieto cesty sa pri použití FWFT spoja do jednej masívnej cesty (tzv. *combinational feedthrough*). Pri vysokých frekvenciách hodín (napr. nad 100 MHz) to zvykne byť hlavnou príčinou zlyhania časovania (Setup Time Violations).
*
**Sanity Check:** Využitie atribútu `(* ramstyle = "no_rw_check" *)`  je pre Quartus správna inštrukcia, ktorá zaručuje efektívne vyvodenie BRAM blokov bez zbytočnej "glue" logiky na riešenie kolízií čítania a zápisu na rovnakú adresu (keďže interné pointre bránia kolíziám).



Celkovo je architektúra pripravená veľmi systematicky. Najväčšiu pozornosť pri nasadzovaní na FPGA je potrebné venovať práve zabezpečeniu neprerušeného signálu `TVALID` pri RX module.
