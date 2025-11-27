import Config

board = System.get_env("PIYOPIYO_BOARD") || "2025-12"

{lcd_cs_pin, sd_cs_pin} =
  case board do
    "2024-05" ->
      {43, 4}

    "2025-12" ->
      {4, 43}

    other ->
      raise """
      Unsupported PIYOPIYO_BOARD=#{inspect(other)}.

      Set PIYOPIYO_BOARD to one of:
        * "2024-05"
        * "2025-12"
      """
  end

spi_config = [
  bus_config: [sclk: 7, miso: 8, mosi: 9],
  device_config: [
    spi_dev_lcd: [
      cs: lcd_cs_pin,
      mode: 0,
      clock_speed_hz: 20_000_000,
      command_len_bits: 0,
      address_len_bits: 0
    ],
    spi_dev_touch: [
      cs: 44,
      mode: 0,
      clock_speed_hz: 1_000_000,
      command_len_bits: 0,
      address_len_bits: 0
    ]
  ]
]

config :sample_app,
  board: board,
  spi_config: spi_config,
  sd_cs_pin: sd_cs_pin
