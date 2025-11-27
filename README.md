# Hello AtomVM LCD SPI Example

This is a tiny Elixir/AtomVM demo for the Seeed **XIAO-ESP32S3** featuring:

* A 480×320 ILI9488 LCD driven over SPI
* FAT-formatted SD card support with automatic image loading
* A lightweight HH:MM:SS clock overlay
* Resistive touch input via XPT2046/ADS7846 (with a small on-screen cursor + `x:y` readout)

---

## Hardware Overview

This project uses a **custom breakout board** designed for the XIAO-ESP32S3, with connectors for:

* ILI9488 LCD
* XPT2046/ADS7846 touch controller
* SD card (shared SPI bus)

Two board revisions are supported:

* **2024-05** — original wiring
* **2025-12** — same design except TFT CS ↔︎ SD CS are swapped

These are the boards shown in the photos below.

![](https://github.com/user-attachments/assets/4e33218d-90aa-43cf-a5d8-102912ec05a6)

![](https://github.com/user-attachments/assets/851da792-aef1-41b9-8931-4449079e4f6e)

---

## Wiring

The table below shows the wiring for the **2024-05** board type.

| Function | XIAO-ESP32S3 pin | ESP32-S3 GPIO |
| -------- | ---------------- | ------------- |
| SCLK     | D8               | 7             |
| MISO     | D9               | 8             |
| MOSI     | D10              | 9             |
| TFT CS   | —                | 43            |
| Touch CS | —                | 44            |
| TFT D/C  | D2               | 3             |
| TFT RST  | D1               | 2             |
| SD CS    | D3               | 4             |

For the **2025-12** revision, these two lines change:

* **TFT CS → GPIO4**
* **SD CS → GPIO43**

---

## Build & Flash

```sh
# 1. Install dependencies
mix deps.get

# 2. Select board type (default: 2025-12)
export PIYOPIYO_BOARD=2024-05
# or
export PIYOPIYO_BOARD=2025-12

# 3. Build the AVM image
# NOTE: Run `mix clean` whenever you change PIYOPIYO_BOARD.
mix clean
mix atomvm.packbeam   # outputs _build/atomvm/main.avm

# 4. Flash to the ESP32-S3
mix atomvm.esp32.flash --port /dev/ttyACM0 --baud 115200
```

---

## `.RGB` Images

* Raw RGB888 (no header), top-left origin
* Exact size: **480 × 320 × 3 = 460,800 bytes**
* Place the files at the SD card root; a fallback `priv/default.rgb` is used if none are found
