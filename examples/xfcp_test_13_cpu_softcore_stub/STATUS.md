# xfcp_test_13_cpu_softcore_stub — STATUS

**Stav:** UZAVRETY  
**Datum:** 2026-06-17  
**Tag:** `xfcp_lib_v1_7_cpu_stub_pass` @ af902a8

---

## Výsledky

| Faza        | Stav  | Detail                                      |
|-------------|-------|---------------------------------------------|
| Simulácia   | PASS  | T01–T54, 0 failures, commit bdbd2d4         |
| Timing      | PASS  | SEED=7, CLK125 WNS +0.241 ns, commit c640411|
| HW UART     | PASS  | 102/102, commit af902a8                     |
| HW UDP      | PASS  | 102/102, commit af902a8                     |

---

## Čo tento test overuje

- `xfcp_cpu_stub.sv`: 4-stavový FSM (ST_IDLE / ST_RX / ST_PROC / ST_TX)
  - PING (4B) → PONG (4B)
  - iný payload → ERR\n (4B), MAX_CMD_BYTES=8
- `axil_cpu_mailbox.sv` native CPU porty — CPU priorita pred AXI-Lite
- Bidirekcionálny mailbox tok: host STREAM_WRITE sid=1 → CPU stub → host STREAM_READ sid=1

## Testy TB (T01–T54)

```
T01–T17   PING / základná komunikácia
T18       STREAM_WRITE sid=1 → RX_LEVEL==0 (stub spotreboval) + TX ERR\n
T19–T37   READ/WRITE/STATUS regresia
T38       TX flush pred AXIL priamym testom
T39–T43   MEM/AXIL regresia
T44       STREAM_WRITE 256B → stub ERR\n odpoveď
T45–T49   CPUM register sanity (stub-aware)
T50       PING → PONG (1x)
T51       ABCD → ERR\n (1x)
T52       PING × 4 (loop)
T53       STR0 izolácia (sid=0 neovplyvnený stubom na sid=1)
T54       8B PING+xxxx → ERR\n (MAX_CMD_BYTES limit)
```

## HW test (`make test-uart` / `make test-udp`)

```
--caps --targets --rw --stream --cpum --stub --mem --diag --repeat 3
```

---

## Kľúčové architektonické rozhodnutia

- `xfcp_cpu_stub.sv` je v `rtl/` example projektu, nie v root `rtl/xfcp/` (demo/test IP)
- CPU porty majú prioritu: `axil_rx_pop_w = ... && !cpu_rx_pop_i`
- Stub číta celý command do interného buffra (max 8B), potom generuje odpoveď
- T18/T44/T46/T48 prepísané vs test_12: stub konzumuje RX okamžite

---

## Ďalší krok

**Fáza C** — knižničná konsolidácia (`xfcp_lib_core_cleanup`):

```
jeden zdroj pravdy pre RTL:    rtl/xfcp/
jeden zdroj pravdy pre Python: tools/xfcp/
aktualne docs/xfcp/
minimum Quartus warningov
manifest / ip.yaml pre kniznica
```
