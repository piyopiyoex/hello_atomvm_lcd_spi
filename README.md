# Hello AtomVM LCD SPI Example

This is a tiny Elixir/AtomVM demo for the Seeed **XIAO-ESP32S3** featuring:

* A 480×320 ILI9488 LCD driven over SPI
* FAT-formatted SD card support with automatic image loading
* A lightweight HH:MM:SS clock overlay
* Resistive touch input via XPT2046/ADS7846 (with a small on-screen cursor + `x:y` readout)

<p align="center">
  <img src="https://github.com/user-attachments/assets/851da792-aef1-41b9-8931-4449079e4f6e" alt="Piyopiyo PCB" width="320">
</p>

---

## Hardware Overview

This project uses a **custom breakout board** designed for the XIAO-ESP32S3, with connectors for:

* ILI9488 LCD
* XPT2046/ADS7846 touch controller
* SD card (shared SPI bus)

All hardware-related materials are maintained in a dedicated repository:

- [piyopiyoex/piyopiyo-pcb](https://github.com/piyopiyoex/piyopiyo-pcb)

For board assembly, pinout verification, or revision-specific details, the PCB
repository should be treated as the authoritative source.

The firmware supports the following board revisions:

- **v1.5 or lower** — original wiring
- **v1.6 or higher** — same board, except LCD-CS and SD-CS are swapped

These are the boards shown in the photos below.

<p align="center">
  <img src="https://github.com/user-attachments/assets/4e33218d-90aa-43cf-a5d8-102912ec05a6" alt="Piyopiyo PCB" width="320">
</p>

---

## Wiring

Base wiring for **v1.5 (and lower)**:

| Function | XIAO-ESP32S3 pin | ESP32-S3 GPIO |
| -------- | ---------------- | ------------- |
| SCLK     | D8               | 7             |
| MISO     | D9               | 8             |
| MOSI     | D10              | 9             |
| LCD CS   | —                | 43            |
| Touch CS | —                | 44            |
| LCD D/C  | D2               | 3             |
| LCD RST  | D1               | 2             |
| SD CS    | D3               | 4             |

For **v1.6 (and higher)**, these two swap:

* **LCD CS → GPIO4**
* **SD CS → GPIO43**

---

## Build & Flash

```sh
# 1. Install dependencies
mix deps.get

# 2. Select board version (default: v1.6)
export PIYOPIYO_BOARD=v1.5
# or
export PIYOPIYO_BOARD=v1.6

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
