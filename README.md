Tiny Elixir/AtomVM demo for the Seeed XIAO-ESP32S3 that:

- Initializes a 480×320 ILI9488 over SPI (RGB666 panel, RGB888 on wire)
- Mounts an SD card (FAT), lists files, and blits the first `*.RGB` full-screen
- Shows a lightweight HH:MM:SS overlay
- Reads XPT2046/ADS7846 touch, draws a small cursor box, and prints a tiny `x:y` OSD

![](https://github.com/user-attachments/assets/851da792-aef1-41b9-8931-4449079e4f6e)

---

## Wiring

The table below shows the wiring for the `2024-05` board type.

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

For the `2025-12` board type, TFT CS and SD CS are swapped:

- TFT CS: GPIO4
- SD CS: GPIO43

---

## Build & Flash

```sh
# Get deps & compile
mix deps.get

# Select board type via PIYOPIYO_BOARD (default: ergo-2025-12)
export PIYOPIYO_BOARD=2024-05
# or
export PIYOPIYO_BOARD=2025-12

# Package BEAMs into an AVM (outputs _build/atomvm/main.avm)
mix atomvm.packbeam

# Flash to ESP32-S3 (adjust port if needed)
mix atomvm.esp32.flash --port /dev/ttyACM0 --baud 115200
```

---

## `.RGB` images

- Raw RGB888, no header, top-left origin.
- Exact size: 480 × 320 × 3 = 460,800 bytes.
- Place on the SD card root; fallback is `priv/default.rgb`.
