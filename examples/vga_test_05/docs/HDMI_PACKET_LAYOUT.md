# HDMI Packet Layout Reference

This document is the single source of truth for all HDMI packet byte layouts
implemented in `rtl/hdmi/`. Any discrepancy between this document,
the packet builder RTL, and the corresponding testbench is a bug.

Reference: HDMI 1.3 specification, CEA-861-D.

---

## Packet type codes (HB0)

| Type                | HB0    | Source file                   |
|---------------------|--------|-------------------------------|
| General Control (GCP)    | `0x00` | `gcp_packet_builder.sv`  |
| Audio Clock Regen (ACR)  | `0x01` | `acr_packet_builder.sv`  |
| Audio Sample             | `0x02` | `audio_sample_packet_builder.sv` |
| AVI InfoFrame            | `0x82` | `infoframe_builder.sv`   |
| Audio InfoFrame          | `0x84` | `infoframe_builder.sv`   |
| SPD InfoFrame            | `0x83` | `infoframe_builder.sv`   |

---

## General Control Packet (GCP)

HDMI 1.4a §8.2.2. Sent every frame to indicate color depth and AVMUTE state.

### Header

| Byte | Value  | Field           |
|------|--------|-----------------|
| HB0  | `0x00` | Packet type     |
| HB1  | `0x00` | Reserved        |
| HB2  | `0x00` | Reserved        |

### Subpacket byte 0 (PB0)

```
[7]   Set_AVMUTE    — set by avmute_i
[6]   Clear_AVMUTE  — set by clear_avmute_i
[5:4] Reserved = 00
[3:0] CD (color depth) = 0000 (not indicated, 24-bit operation)
```

All other bytes are `0x00`.

---

## Audio Clock Regeneration Packet (ACR)

HDMI 1.3 Table 7-3. MSB-first byte order for both N and CTS.

### Header

| Byte | Value  | Field                  |
|------|--------|------------------------|
| HB0  | `0x01` | Packet type            |
| HB1  | `0x00` | Reserved               |
| HB2  | `0x00` | Reserved               |

### Subpacket layout (4 identical subpackets, indices SP0..SP3)

Each subpacket spans 7 bytes: `pb_o[sp*7 + 0]` .. `pb_o[sp*7 + 6]`.

| PB offset | Value                  | Field             |
|-----------|------------------------|-------------------|
| 0         | `{4'h0, CTS[19:16]}`   | CTS MSB nibble    |
| 1         | `CTS[15:8]`            | CTS mid byte      |
| 2         | `CTS[7:0]`             | CTS LSB           |
| 3         | `{4'h0, N[19:16]}`     | N MSB nibble      |
| 4         | `N[15:8]`              | N mid byte        |
| 5         | `N[7:0]`               | N LSB             |
| 6         | `0x00`                 | Reserved          |

**Byte order: MSB-first.** CTS[19:16] appears before CTS[7:0]; N[19:16] before N[7:0].

Example for `N=6144 (0x001800)`, `CTS=40000 (0x009C40)`:

```
PB0 = 0x00  (4'h0 + CTS[19:16]=0)
PB1 = 0x9C  (CTS[15:8])
PB2 = 0x40  (CTS[7:0])
PB3 = 0x00  (4'h0 + N[19:16]=0)
PB4 = 0x18  (N[15:8])
PB5 = 0x00  (N[7:0])
PB6 = 0x00
```

All four subpackets are identical (same N and CTS values repeated).

---

## Audio Sample Packet

HDMI 1.3 §7.3. 2-channel LPCM, 4 sample pairs per packet. Left-justified 16-bit in 24-bit audio word.

### Header

| Byte | Value  | Field                                          |
|------|--------|------------------------------------------------|
| HB0  | `0x02` | Packet type                                    |
| HB1  | `0x0F` | B=0; SP[3:0]=4'b1111 (all 4 subpackets present) |
| HB2  | `0x00` | LAYOUT=0 (2-channel); flat bits = 0            |

### Audio word encoding (AW)

16-bit sample is left-justified in a 24-bit AW:

```
AW[23:8] = sample[15:0]
AW[7:0]  = 8'h00
```

Parity: `P = ^sample[15:0]` (V=U=C=0).

### Subpacket layout (SP0..SP3)

Each subpacket covers 7 bytes: `pb_o[sp*7 + 0]` .. `pb_o[sp*7 + 6]`.

| PB offset | Value                          | Field                       |
|-----------|--------------------------------|-----------------------------|
| 0         | `{3'b000, ^R, 3'b000, ^L}`     | Parity bytes (P1, P0)       |
| 1         | `8'h00`                        | L AW[7:0]  = 0 (unused)    |
| 2         | `L[7:0]`                       | L AW[15:8] = L sample LSB   |
| 3         | `L[15:8]`                      | L AW[23:16] = L sample MSB  |
| 4         | `8'h00`                        | R AW[7:0]  = 0 (unused)    |
| 5         | `R[7:0]`                       | R AW[15:8] = R sample LSB   |
| 6         | `R[15:8]`                      | R AW[23:16] = R sample MSB  |

---

## AVI InfoFrame

CEA-861-D §6.4. Sent once per frame to describe video format.

### Header

| Byte | Value  | Field                                  |
|------|--------|----------------------------------------|
| HB0  | `0x82` | InfoFrame type (CEA INFO_AVI)          |
| HB1  | `0x02` | Version 2                              |
| HB2  | `0x0D` | Length = 13 (PB1..PB13)               |

### Payload

| Byte | Value / Bits                              | Field                      |
|------|-------------------------------------------|----------------------------|
| PB0  | checksum                                  | `-(HB0+HB1+HB2+PB1..PB13)` mod 256 |
| PB1  | `{1'b0, Y1:Y0, 1'b1, 2'b00, 2'b00}`      | Color format; AFID=1; no bar/scan info |
| PB2  | `{2'b00, M1:M0, 4'b1000}`                 | Colorimetry; aspect ratio; R=same as pic AR |
| PB3  | `{1'bX, 3'b000, Q1:Q0, 2'b00}`            | EC=unspec; quantization range; no scaling |
| PB4  | VIC code                                  | Video Identification Code  |
| PB5..PB13 | `0x00`                               | Pixel rep, bar info (unused) |

**Color format** (`Y1:Y0` = `color_format_i`):
- `2'b00` = RGB
- `2'b01` = YCbCr 4:2:2
- `2'b10` = YCbCr 4:4:4

**Aspect ratio** (`M1:M0` = `aspect_ratio_i`):
- `2'b00` = no data
- `2'b01` = 4:3
- `2'b10` = 16:9

**Quantization range** (`Q1:Q0` = `quant_range_i`):
- `2'b00` = default (per video format)
- `2'b01` = limited
- `2'b10` = full

---

## Audio InfoFrame

CEA-861-D §6.6.1.

### Header

| Byte | Value  | Field                              |
|------|--------|------------------------------------|
| HB0  | `0x84` | InfoFrame type (CEA INFO_AUDIO)    |
| HB1  | `0x01` | Version 1                          |
| HB2  | `0x0A` | Length = 10 (PB1..PB10)           |

### Payload

| Byte | Value / Bits             | Field                         |
|------|--------------------------|-------------------------------|
| PB0  | checksum                 | `-(HB0+HB1+HB2+PB1..PB10)` mod 256 |
| PB1  | `{5'b0, CC[2:0]}`        | CT=PCM; CC = channel count - 1 |
| PB2..PB10 | `0x00`            | Fs, SS, speaker map (unused)  |

**Channel count** (`CC[2:0]` = `audio_channels_i`): value = number_of_channels − 1.
Example: stereo → `CC=1` (2−1).

---

## SPD InfoFrame

CEA-861-D §6.5.

### Header

| Byte | Value  | Field               |
|------|--------|---------------------|
| HB0  | `0x83` | InfoFrame type      |
| HB1  | `0x01` | Version 1           |
| HB2  | `0x19` | Length = 25 (PB1..PB25) |

### Payload

| Byte     | Content                        |
|----------|--------------------------------|
| PB0      | Checksum                       |
| PB1..PB8 | Vendor name (8 bytes, LSB first from `vendor_name_i[63:0]`) |
| PB9..PB24 | Product description (16 bytes, LSB first from `product_desc_i[127:0]`) |
| PB25     | Source Device Info (`source_device_i`) |

---

## Consistency requirements

The following three artefacts must stay consistent for each packet type:

| Artefact                       | ACR         | Audio Sample          | AVI / Audio IF         |
|--------------------------------|-------------|-----------------------|------------------------|
| Builder RTL                    | `acr_packet_builder.sv` | `audio_sample_packet_builder.sv` | `infoframe_builder.sv` |
| Testbench                      | `tb_acr_packet_builder.sv` | `tb_audio_sample_packet_builder.sv` | `tb_hdmi_tx_core_32x10.sv` |
| This document                  | ACR section | Audio Sample section  | AVI / Audio IF sections |

If any of the three diverges, the simulation regression must fail.
