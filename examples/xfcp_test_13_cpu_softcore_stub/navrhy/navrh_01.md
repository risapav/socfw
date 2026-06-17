Skontroloval som aktuálny `xfcp_test_13_cpu_softcore_stub.zip` aj priložené `docs(3).zip` a `rtl(2).zip`.

```text
xfcp_test_13_cpu_softcore_stub.zip
SHA-256: a766c49ef38791eb342d6d99e296999bf1f7e21abaeee8b056baf90aa7f67bfe

docs(3).zip
SHA-256: 41f57896143cfcf7d3d642cdc1a6e8164ccd2ff427ac634c95ede9c26b1ac5ee

rtl(2).zip
SHA-256: fef2afc04161e52c19b3fce57b3a332aeb59eab7615018a4be662be3a7b25958
```

## Verdikt

`xfcp_test_13` je **architektonicky na správnej ceste**, ale aktuálny ZIP ešte **nie je míľnik PASS**.

Najdôležitejší stav:

```text
RTL architektúra:       dobrá
CPU native porty:       pridané
xfcp_cpu_stub.sv:       pridaný
HW test --stub:         pripravený
Dokumentácia:           už ráta s v1.7
Simulácia:              FAIL, 30 failures
Timing/HW:              nedoložené v ZIP-e
```

Teda aktuálne označenie:

```text
xfcp_test_13_cpu_softcore_stub_sim_fail
```

nie ešte:

```text
xfcp_lib_v1_7_cpu_stub_pass
```

---

# Čo je dobré

## 1. `axil_cpu_mailbox.sv` má správne native CPU porty

V `rtl(2).zip` je `axil_cpu_mailbox.sv` už rozšírený o CPU-side porty:

```systemverilog
cpu_rx_data_o
cpu_rx_valid_o
cpu_rx_pop_i

cpu_tx_data_i
cpu_tx_push_i
cpu_tx_ready_o
```

A komentár správne definuje handshake aj prioritu CPU portu pred AXI-Lite. Toto je presne správny smer pre budúce CPU pripojenie.

Dôležité pozitívum:

```systemverilog
wire axil_rx_pop_w = ... && !cpu_rx_pop_i;
assign rx_r_ready_w = axil_rx_pop_w || cpu_rx_pop_i;
```

To znamená, že CPU pop blokuje súčasný AXI-Lite pop. To je správne.

Aj TX má CPU prioritu:

```systemverilog
wire axil_tx_push_w = ... && !cpu_tx_push_i;
assign tx_w_valid_w = cpu_tx_push_i || axil_tx_push_w;
assign tx_w_data_w  = cpu_tx_push_i ? cpu_tx_data_i : s_axil.WDATA[8:0];
```

Aj to je správny základ.

---

## 2. `xfcp_cpu_stub.sv` je rozumne oddelený

V example projekte je:

```text
rtl/xfcp_cpu_stub.sv
```

Nie je v `rtl/axil/`, čo je dobre. Je to demo/test CPU-side agent, nie AXI-Lite modul.

FSM robí presne to, čo sme chceli:

```text
PING -> PONG
iné -> ERR\n
```

A používa mailbox native CPU porty, nie AXI-Lite registre. To je správna architektúra.

---

## 3. `test_hw.py --stub` je pripravený

V `tools/test_hw.py` už existuje:

```text
--stub
run_stub_test()
```

A testuje:

```text
PING -> PONG
unknown -> ERR\n
opakovaný PING
```

To je dobrý HW testovací smer.

---

## 4. Dokumentácia už je pripravená na v1.7

V `docs(3).zip` vidno, že `docs/xfcp/version.md` už spomína:

```text
v1.7 — CPU softcore stub (xfcp_test_13)
```

A existuje aj `docs/xfcp/backend_mailbox.md`. To je dobré, ale kým sim/HW neprejde, v1.7 nesmie byť označená ako uzavretá.

---

# Hlavný problém: simulácia zlyháva

Sim transcript končí:

```text
FAILURES DETECTED (30 failures)
```

Zaujímavé je, že nové stub testy na konci **prechádzajú**:

```text
T50 PING -> PONG PASS
T51 ABCD -> ERR\n PASS
T52 PING x4 PASS
T53 STR0 izolácia PASS
T54 PING+extra -> ERR\n PASS
```

Čiže samotný `xfcp_cpu_stub.sv` funguje.

Zlyhávajú ale staršie CPUM register testy:

```text
T45 TX_PUSH_DATA -> STREAM_READ
T46 STREAM_WRITE sid=1 -> RX_POP_DATA
T48 STATUS rx_not_empty
T49 TX FIFO flush
```

To je presne dôsledok zmeny architektúry: v teste 12 bol CPU0 mailbox pasívny, takže AXI-Lite testy mohli kontrolovať FIFO obsah priamo. V teste 13 je už k mailboxu pripojený aktívny CPU stub, ktorý FIFO priebežne číta a zapisuje odpovede.

Inými slovami:

```text
T12 očakávanie:
  host zapíše do RX FIFO
  dáta ostanú v RX FIFO
  AXI-Lite RX_POP_DATA ich prečíta

T13 realita:
  host zapíše do RX FIFO
  CPU stub ich okamžite prečíta
  RX FIFO je prázdne
  TX FIFO obsahuje PONG alebo ERR\n
```

Preto T46 napríklad očakáva pôvodné bajty `A1 B2 C3 ...`, ale stub ich už spracoval a v TX FIFO je odpoveď `ERR\n`. To nie je chyba stubu. Je to chyba regresie: testbench mieša dva režimy mailboxu.

---

# Druhý problém: T45/T49 sú rušené zvyškami v TX FIFO

V T45 sa očakáva:

```text
TX_LEVEL == 4
STREAM_READ -> 12 34 56 78
```

Ale sim ukazuje:

```text
TX_LEVEL got 0x0C
rd[0..3] got EE FF 01 02
```

To znamená, že v TX FIFO už boli staršie dáta pred T45. Teda test začína so špinavým TX FIFO alebo sa flush nestihol/aplikoval nesprávne vzhľadom na aktívny stub.

Toto je typický problém pri aktívnom agente:

```text
test pustí AXI-Lite TX_PUSH_DATA,
ale stub zároveň môže tlačiť vlastné ERR/PONG odpovede,
takže TX FIFO už nie je výlučne pod kontrolou testu.
```

Preto CPUM AXI-Lite register testy treba v `xfcp_test_13` buď upraviť, alebo rozdeliť režimy.

---

# Ako to správne opraviť

Máme dve rozumné možnosti. Odporúčam prvú.

## Možnosť A — pridať `STUB_ENABLE` parameter

Do topu pridať parameter:

```systemverilog
parameter bit ENABLE_CPU_STUB = 1'b1
```

A pripojiť stub iba keď je enabled.

Keď je disabled:

```systemverilog
assign stub_rx_pop_w  = 1'b0;
assign stub_tx_data_w = 9'h000;
assign stub_tx_push_w = 1'b0;
```

Potom v testbenchi môžeš mať dva DUT režimy alebo dva sim targety:

```text
A) mailbox_regs mode:
   ENABLE_CPU_STUB=0
   T01–T49 pôvodné CPUM register testy

B) cpu_stub mode:
   ENABLE_CPU_STUB=1
   T01–T44 základná regresia
   T50–T54 PING/PONG/ERR/stub izolácia
```

Toto je najčistejšie, lebo zachováva test 12 semantics aj test 13 semantics.

---

## Možnosť B — prepísať T45–T49 pre aktívny stub

Ak nechceš parameter, musíš v `xfcp_test_13` upraviť T45–T49 tak, aby rátali s aktívnym stubom.

Napríklad:

```text
T45 AXI-Lite TX_PUSH_DATA -> STREAM_READ
  môže ostať, ale pred testom musíš:
    - tx_flush
    - počkať
    - overiť TX_LEVEL==0
    - zabezpečiť, že stub práve nič neposiela

T46 STREAM_WRITE sid=1 -> RX_POP_DATA
  už v T13 nedáva zmysel,
  lebo stub má RX FIFO spotrebovať.
  Treba očakávať RX_LEVEL==0 a TX ERR\n.

T48 STATUS rx_not_empty==1
  už nedáva zmysel s aktívnym stubom.
  Správne je rx_not_empty==0 po spotrebovaní stubom.

T49 TX flush
  pred testom musí byť čistý TX FIFO.
```

Časť T46/T48 už sa v kóde snaží upraviť, ale transcript ukazuje, že nie všade je test izolovaný od zvyškov TX FIFO.

---

# Moje odporúčanie

Pre knižnicu by som zvolil **Možnosť A**.

Prečo?

Lebo `axil_cpu_mailbox.sv` je knižničný modul a potrebuje dve nezávislé testovacie vrstvy:

```text
1. mailbox register/FIFO test bez CPU agenta
2. CPU agent integration test so stubom
```

Ak budeš testovať všetko naraz s aktívnym stubom, AXI-Lite register testy budú krehké, lebo FIFO už vlastní CPU agent.

Takže:

```text
xfcp_test_12_cpu_mailbox_regs:
  testuje axil_cpu_mailbox pasívne

xfcp_test_13_cpu_softcore_stub:
  testuje aktívne CPU-side použitie mailboxu
```

V `xfcp_test_13` by som už neopakoval všetky hlboké CPUM register testy T45–T49 v pôvodnom zmysle. Stačí sanity:

```text
CPUM ID
STATUS readable
TX/RX flush commands do not break
```

A hlavné testy majú byť:

```text
PING -> PONG
unknown -> ERR\n
repeat PING
STR0 isolation
MEM/AXIL regression still OK
DIAG clean
```

---

# Konkrétne kroky teraz

## Krok 1 — upraviť sim regresiu

V `tb_xfcp_test_13_cpu_softcore_stub_top.sv` sprav jedno z týchto:

### Preferované:

Rozdeľ testy:

```text
T01–T44 všeobecná regresia
T45–T49 buď vypnúť alebo zmeniť na stub-aware sanity
T50–T54 stub-specific testy
```

Alebo pridaj `ENABLE_CPU_STUB=0/1` režimy.

Najrýchlejšia praktická oprava:

```text
- T45 ponechať len ak pred ním spravíš tx_flush a overíš TX_LEVEL==0.
- T46 zmeniť na očakávanie RX_LEVEL==0 + STREAM_READ ERR\n.
- T48 očakávať rx_not_empty==0, nie 1.
- T49 pred testom tx_flush + overiť TX_LEVEL==0.
```

Podľa kódu sa o to už snažíš, ale transcript stále ukazuje, že TX FIFO nie je čisté. Preto by som pred T45 a T49 dal tvrdý helper:

```systemverilog
task automatic cpum_tx_flush_and_check_empty();
  logic [31:0] rdata;
  xfcp_write(32'hFF07_0004, 32'h2, seq); drain_write_resp();
  repeat (20) @(posedge clk_i);
  xfcp_read(32'hFF07_0014, seq2); recv_read(rdata);
  chk32(rdata, 32'h0, "CPUM.TX_LEVEL==0 after flush");
endtask
```

A po každom `STREAM_WRITE sid=1` s ne-PING payloadom musíš drainúť `ERR\n`.

---

## Krok 2 — upraviť status

Aktuálny stav nesmie tvrdiť PASS. Stav by mal byť:

```text
Sim: FAIL, 30 failures
Root cause:
  T12 mailbox register tests are not fully compatible with active CPU stub.
  Stub consumes RX FIFO and produces TX responses, so AXI-Lite FIFO tests need stub-aware rewrite or ENABLE_CPU_STUB=0 mode.
```

---

## Krok 3 — po sim PASS riešiť timing

V ZIP-e nevidím STA reporty pre test 13. Po sim fix-e:

```bash
make compile
```

Cieľ:

```text
CLK125 WNS >= 0
TNS = 0
ETH_RXC PASS
```

---

## Krok 4 — HW až po sim/timing

Až potom:

```bash
make hw-regression
```

A Makefile/test_hw by mal obsahovať:

```text
--caps --targets --rw --stream --cpu0 --cpum --stub --mem --diag
```

V `tools/test_hw.py` už `--stub` existuje, čo je dobré.

---

# Stav docs a rtl

`rtl(2).zip` vyzerá ako dobrý root RTL snapshot pre v1.6 plus CPU-native porty. Ale `xfcp_cpu_stub.sv` nie je v root `rtl/`, iba v example. To je podľa mňa správne, kým je to demo stub.

`docs(3).zip` je pripravené smerom k v1.7, ale nesmie označiť v1.7 ako hotové, kým test 13 nedá:

```text
sim PASS
timing PASS
HW UART+UDP PASS
```

---

## Záver

Progres je dobrý, ale narazil si na očakávateľný problém:

```text
Pridaním aktívneho CPU stubu sa zmenila semantika CPU0 mailbox FIFO.
Staré CPUM register testy už nemôžu predpokladať, že RX/TX FIFO ostanú pasívne.
```

Samotný nový stub funguje — T50 až T54 prechádzajú. Zlyháva kompatibilita starších T45–T49 testov s aktívnym agentom.

Odporúčaný ďalší postup:

```text
1. Rozdeliť pasívne mailbox-reg testy a aktívne stub testy.
2. V test 13 ponechať CPUM len ako sanity + stub integration.
3. Alebo pridať ENABLE_CPU_STUB parameter pre dva režimy.
4. Opraviť sim, kým T01–T54 nedá 0 failures.
5. Potom timing.
6. Potom HW regression s --stub.
```

Až potom bude možné tagovať:

```text
xfcp_lib_v1_7_cpu_softcore_stub_pass
```
