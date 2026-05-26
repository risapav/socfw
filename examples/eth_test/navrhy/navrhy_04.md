MDIO/MDC pri **RTL8211EG** slúži ako **manažment rozhranie PHY čipu**. Nie je to dátová cesta Ethernet rámcov. Dáta idú cez GMII/RGMII signály ako `TXD`, `RXD`, `TX_EN`, `RX_DV`, `GTX_CLK`, `RX_CLK`. MDIO/MDC je bočné sériové rozhranie na konfiguráciu a čítanie stavov PHY.

Podľa datasheetu RTL8211EG management interface sprístupňuje interné registre cez piny **MDC** a **MDIO** podľa IEEE 802.3u Clause 22; **MDC generuje MAC/FPGA** a **MDIO je obojsmerný dátový signál** synchronizovaný s MDC. ([datasheet.lcsc.com][1])

## Signály

```text
MDC  = Management Data Clock
       výstup z FPGA/MAC do PHY
       typicky max. 2.5 MHz pri Clause 22

MDIO = Management Data Input/Output
       obojsmerný open-drain / tri-state dátový pin
       FPGA ho pri write poháňa, pri read ho musí pustiť do Z
```

MDIO zvyčajne potrebuje pull-up rezistor. Pre podobné Realtek PHY datasheety sa uvádza pull-up rádovo okolo 1.5 kΩ; všeobecne sa MDIO používa ako bidirectional management bus s pull-upom. ([akizukidenshi.com][2])

## Na čo ho použiješ v `eth_test`

Cez MDIO/MDC vieš z FPGA čítať a nastavovať registre RTL8211EG, napríklad:

```text
- zistiť, či je link up/down
- zistiť vyrokovanú rýchlosť: 10 / 100 / 1000 Mbps
- zistiť duplex: half / full
- spustiť alebo zakázať auto-negotiation
- reštartovať auto-negotiation
- dať PHY do resetu alebo power-down režimu
- nastaviť loopback režim
- čítať PHY ID registre
- čítať vendor-specific registre Realteku
- nastavovať oneskorenia RGMII TX/RX clocku, ak ich PHY podporuje cez registre alebo strap konfiguráciu
```

Pre bring-up je najdôležitejšie čítať tieto základné Clause 22 registre:

```text
reg 0  BMCR  Basic Mode Control Register
reg 1  BMSR  Basic Mode Status Register
reg 2  PHYID1
reg 3  PHYID2
reg 4  Auto-Negotiation Advertisement
reg 5  Auto-Negotiation Link Partner Ability
```

Prakticky: ak máš v FPGA MDIO master, vieš po resete urobiť napríklad:

```text
1. prečítať PHYID1/PHYID2
   overíš, že RTL8211EG odpovedá a PHY adresa je správna

2. prečítať BMSR
   overíš link status a auto-negotiation complete

3. podľa statusu nastaviť MAC/RGMII logiku
   napr. 1000 Mbps -> 125 MHz
        100 Mbps  -> 25 MHz
        10 Mbps   -> 2.5 MHz
```

## Prečo ti to teraz v `eth_test` vadí

V tvojom aktuálnom RTL máš porty:

```systemverilog
output logic eth_mdc_o;
inout  wire  eth_mdio_io;
```

ale nie sú reálne zapojené. Preto Quartus hlási, že `ETH_MDC` nemá driver a `ETH_MDIO` je stuck/undefined. To neznamená, že Ethernet dáta nutne nemôžu fyzicky bežať, ale znamená to, že FPGA nevie PHY konfigurovať ani čítať jeho stav.

Pre minimálny test môžeš MDIO/MDC dočasne ošetriť takto:

```systemverilog
assign eth_mdc_o   = 1'b0;
assign eth_mdio_io = 1'bz;
```

To je iba „nepoužívam MDIO“ režim. PHY potom musí byť správne nakonfigurované strap pinmi na doske.

## Odporúčanie pre tvoj framework

Pre `eth_test` by som rozlíšil dva režimy:

### 1. Minimal PHY strap mode

Použiješ iba dátové rozhranie a PHY konfiguráciu necháš na strapoch dosky.

```systemverilog
assign eth_mdc_o   = 1'b0;
assign eth_mdio_io = 1'bz;
```

V YAML by som to označil napríklad:

```yaml
features:
  use:
    - board:onboard.eth
  options:
    eth_mdio: disabled
```

### 2. Managed PHY mode

Doplníš MDIO master modul. Po resete spravíš:

```text
read PHYID1/PHYID2
wait link up
wait autoneg complete
read speed/duplex
release MAC TX/RX logic
```

Toto je vhodnejší režim pre robustný príklad `eth_test`, lebo test potom vie hlásiť:

```text
PHY detected
link up
1000BASE-T full duplex
ready to transmit
```

## Pointa

`MDIO/MDC` je konfiguračný a diagnostický kanál medzi FPGA/MAC a RTL8211EG PHY. Bez neho si odkázaný na hardvérové strap nastavenia PHY a nevieš spoľahlivo zistiť link status, rýchlosť, duplex ani PHY ID. Pre prvý jednoduchý test ho môžeš dať do bezpečného neaktívneho stavu, ale pre seriózny `eth_test` by som určite pridal malý MDIO master.

[1]: https://datasheet.lcsc.com/datasheet/pdf/4db0b5f392a00cbc87420d89cf1d417f.pdf?productCode=C90735&utm_source=chatgpt.com "INTEGRATED 10/100/1000M ETHERNET TRANSCEIVER"
[2]: https://akizukidenshi.com/goodsaffix/RTL8211C%28L%29_DataSheet_1.5.pdf?utm_source=chatgpt.com "Realtek RTL8211C(L) DataSheet 1.5"
