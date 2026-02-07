import Config

board = System.get_env("PIYOPIYO_BOARD") || "v1.6"

raise_invalid_board = fn parts ->
  raise """
  Unsupported PIYOPIYO_BOARD=#{inspect(board)} (parsed parts: #{inspect(parts)}).

  Expected a version-like value such as:

    * "v1.5"
    * "v1.6"
    * "1.5"
    * "1.6.1"
  """
end

version_segments =
  board
  |> String.trim_leading("v")
  |> String.split(".")
  |> case do
    [maj] -> [maj, "0", "0"]
    [maj, min] -> [maj, min, "0"]
    [maj, min, patch] -> [maj, min, patch]
    parts -> raise_invalid_board.(parts)
  end

unless Enum.all?(version_segments, &String.match?(&1, ~r/^\d+$/)) do
  raise_invalid_board.(version_segments)
end

version = version_segments |> Enum.join(".") |> Version.parse!()

{lcd_cs_pin, sd_cs_pin} =
  case Version.compare(version, Version.parse!("1.6.0")) do
    # v1.5 or lower
    :lt -> {43, 4}
    # v1.6 or higher
    _ -> {4, 43}
  end

spi_config = [
  bus_config: [sclk: 7, miso: 8, mosi: 9],
  device_config: [
    spi_dev_display: [
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
