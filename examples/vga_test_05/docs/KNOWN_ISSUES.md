# Known Issues and Technical Debt

---

## PHY-001: TMDS PHY uses free-running 5x pair counter

**Component:** `vga_hdmi_tx.sv` (PHY output stage)

**Description:**
The TMDS serializer uses a free-running modulo-5 counter in `clk_x` domain to align
10-bit TMDS words into DDR bit pairs. There is no explicit word-start strobe or
alignment feedback from the serializer.

This works reliably on the current board at 800×600 / 40 MHz pixel clock because the
`pix_clk` → `clk_x` PLL relationship is stable after reset and the pair counter
self-aligns on the first clock cycle. However the scheme is fragile in general:

- No reset synchronizer for `clk_x` domain — reset de-assertion timing relative to the
  5x clock boundary is undefined.
- A PLL recalibration or clock glitch can leave the pair counter offset by 1..4 positions,
  producing a corrupted TMDS stream without any detectable error.
- No mechanism to force realignment (e.g. a AVMUTE GCP + relock sequence).

**Workaround in use:** none — relies on stable PLL startup behavior.

**Recommended hardening (future):**
1. Add a CDC-safe reset synchronizer for `clk_x` domain, asserting reset until
   the first rising edge of `pix_clk` after `locked` goes high.
2. Add an explicit `word_start_x_i` strobe, asserted once per 5 `clk_x` cycles,
   derived from a `pix_clk`-domain counter and re-synchronized into `clk_x`.
3. Long-term: replace the custom DDR pair output with a vendor serializer primitive
   (e.g. Cyclone IV `ALTLVDS_TX` or `ALTDDIO_OUT`) with guaranteed word alignment.

**Priority:** low — current board passes all video modes tested. Address before
supporting multiple video modes or hot-plug scenarios.

---

## PKT-001: Audio sample rate not rate-limited

**Component:** `hdmi_audio_test_src.sv`, `hdmi_packet_arbiter.sv`

**Description:**
The audio sample packet source (`hdmi_audio_test_src`) currently generates a new
audio sample packet request on every available data island slot. There is no FIFO
and no rate limiter tied to actual audio clock (ACR N/CTS parameters).

For bring-up, this is acceptable: the monitor will receive audio sample packets at
a rate determined entirely by how many hblank slots the arbiter can service, not
by the actual sample rate implied by the ACR N/CTS values. A monitor that validates
the audio sample rate against the ACR-advertised rate may flag a mismatch.

**Recommended hardening (future):**
1. Introduce `hdmi_audio_fifo.sv`: a small FIFO fed from `i2s_rx.sv` or
   `audio_test_tone_gen.sv` at the correct sample rate.
2. Add `audio_packet_scheduler.sv` that releases one audio sample packet per
   `(4 samples / sample_rate)` interval, enforcing the rate contract.
3. Retire `hdmi_audio_test_src.sv` once a real source exists.

**Priority:** medium — impacts audio quality/compatibility, not video stability.

---

## SIM-001: audio_scenarios threshold allows one missed AVI/ACR per simulation

**Component:** `tb_hdmi_tx_core_audio.sv`

**Description:**
The packet count assertions for GCP and AVI use threshold `>= N_FRAMES - 1` rather
than `>= N_FRAMES`. This is intentional: on a frame boundary the packet arbiter
resets to `ARB_GCP` state, preempting an in-progress AVI or ACR sequence for that
frame. The last frame of the simulation window may therefore miss one AVI or ACR
packet.

This is correct arbiter behavior (GCP must be sent every frame). The threshold
relaxation is documented in `tb_hdmi_tx_core_audio.sv` with a comment.

**Not a bug**, but documented here to prevent future confusion when interpreting
simulation results that show `cnt_avi = N_FRAMES - 1`.
