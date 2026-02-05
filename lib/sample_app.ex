defmodule SampleApp do
  @moduledoc """
  End-to-end demo app for an ILI9488 SPI LCD + SD card (FAT) + resistive touch on AtomVM.

  ## What this app demonstrates

  - Driving an ILI9488 in *RGB666 (18-bit)* mode over SPI.
    - The panel is configured for RGB666, but we stream 3 bytes/pixel (RGB888) on the wire.
    - The LCD effectively ignores the low 2 bits of each channel, so RGB888 → RGB666 works by truncation.

  - Sharing one physical SPI bus between multiple “devices”:
    - LCD (writes, large streams)
    - Touch controller (small command/response reads)
    - SD card (mount + file streaming)
    - `SampleApp.SPIBus` acts as the “mutex” so those sequences do not interleave.

  - Blitting raw image files from SD card:
    - We expect a `.RGB` file to be raw RGB888 bytes in row-major order:
      `byte_size == LCD.width() * LCD.height() * 3`
    - Top-left origin, no header, no compression.

  - Drawing a lightweight clock overlay and visualizing touch input.

  ## Boot sequence (high level)

  1) Start SPI bus owner (`SPIBus`)
  2) Initialize LCD, draw sanity bars
  3) Mount `/sdcard` (FAT)
  4) Find first `.RGB`, validate its byte size, and stream to LCD
  5) Start `Clock` (HH:MM:SS)
  6) Start `Touch` reader (sends `{:touch, x, y, z}`)

  ## Notes

  - Pin wiring and SPI host/device config come from `config/config.exs` via `Application.compile_env/2`.
  - All multi-step SPI operations are wrapped in `SPIBus.transaction/2` to keep bus access serialized.
  """

  @compile {:no_warn_undefined, :gpio}
  @compile {:no_warn_undefined, :atomvm}

  alias SampleApp.{Clock, LCD, SD, SPIBus, Touch}

  # SPI host/device configuration and SD chip-select pin come from config at compile time.
  @spi_config Application.compile_env(:sample_app, :spi_config)
  @pin_sd_cs Application.compile_env(:sample_app, :sd_cs_pin)

  # SD mount
  @sd_driver ~c"sdspi"
  @sd_root ~c"/sdcard"

  # Fallback priv image (project app atom, filename in priv/)
  @priv_app :sample_app
  @priv_fallback ~c"default.rgb"

  ## AtomVM entrypoint (mix.exs atomvm.start points here)

  def start() do
    {:ok, _pid} = start_link()
    Process.sleep(:infinity)
  end

  def start_link(opts \\ []) do
    :gen_server.start_link({:local, __MODULE__}, __MODULE__, :ok, opts)
  end

  ## gen_server callbacks

  def init(:ok) do
    :io.format(~c"ILI9488 / RGB24 (RGB666 panel) + SD + Touch demo~n")

    {:ok, _} = SPIBus.start_link(@spi_config)

    # SD uses a discrete CS GPIO. We keep it de-selected unless we are actively mounting/reading.
    # This prevents the SD card from responding while we talk to the LCD/touch devices.
    :gpio.set_pin_mode(@pin_sd_cs, :output)
    :gpio.digital_write(@pin_sd_cs, :high)

    boot_once()

    {:ok, %{}}
  end

  def handle_info({:touch, x, y, _z}, state) do
    # Visual feedback for touch events: draw a tiny 3x3 dot at the reported coordinate.
    # Color uses RGB888 bytes (panel runs RGB666 so low bits are truncated).
    SPIBus.transaction(fn spi ->
      LCD.fill_rect_rgb666(
        spi,
        {max(x - 1, 0), max(y - 1, 0)},
        {3, 3},
        {0x00, 0xFC, 0x00}
      )
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp boot_once() do
    :io.format(~c"[boot] init lcd + sd + first blit~n")

    SPIBus.transaction(fn spi ->
      LCD.initialize(spi)
      LCD.draw_sanity_bars(spi)

      case SD.mount(spi, @pin_sd_cs, @sd_root, @sd_driver) do
        {:ok, _mref} ->
          SD.print_directory(@sd_root)

          case SD.list_rgb_files(@sd_root) do
            [] ->
              :io.format(~c"No .RGB found on SD. Falling back to priv/~s~n", [@priv_fallback])
              blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)

            [first_path | _] ->
              blit_fullscreen_rgb24_from_sd(spi, first_path)
          end

        {:error, reason} ->
          :io.format(~c"SD mount failed (~p). Falling back to priv/~s~n", [
            reason,
            @priv_fallback
          ])

          blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)
      end
    end)

    {:ok, _} = Clock.start_link(h_align: :center, y: 5)
    {:ok, _} = Touch.start_link(notify: self())

    :io.format(~c"[boot] done~n")
    :ok
  end

  ## Blit helpers (RGB24 only)

  defp blit_fullscreen_rgb24_from_sd(spi, path) do
    width = LCD.width()
    height = LCD.height()
    pixels = width * height
    need = pixels * 3
    chunk = LCD.max_chunk_bytes()

    size =
      case SD.file_size(path, chunk) do
        {:ok, s} -> s
        _ -> -1
      end

    if size != need do
      :io.format(
        ~c"[SD] ~s: size ~p does not match expected ~p (W×H×3). Skipping.~n",
        [path, size, need]
      )

      :error
    else
      :io.format(~c"[SD] Blit ~s as ~p x ~p (RGB24)~n", [path, width, height])

      LCD.set_window(spi, {0, 0}, {width - 1, height - 1})
      LCD.begin_ram_write(spi)
      SD.stream_file_chunks(path, chunk, fn bin -> LCD.spi_write_chunks(spi, bin) end)

      :io.format(~c"[SD] Blit done.~n")
      :ok
    end
  end

  defp blit_fullscreen_rgb24_from_priv(spi, app_atom, filename) do
    width = LCD.width()
    height = LCD.height()
    pixels = width * height
    need = pixels * 3

    case :atomvm.read_priv(app_atom, filename) do
      bin when is_binary(bin) and byte_size(bin) == need ->
        :io.format(~c"[priv] Blit ~s as ~p x ~p (RGB24)~n", [filename, width, height])

        LCD.set_window(spi, {0, 0}, {width - 1, height - 1})
        LCD.begin_ram_write(spi)
        LCD.spi_write_chunks(spi, bin)

        :io.format(~c"[priv] Blit done.~n")
        :ok

      bin when is_binary(bin) ->
        :io.format(
          ~c"[priv] ~s size ~p does not match expected ~p (W×H×3). Skipping.~n",
          [filename, byte_size(bin), need]
        )

        :error

      other ->
        :io.format(~c"[priv] Could not read ~s (got ~p).~n", [filename, other])
        :error
    end
  end
end
