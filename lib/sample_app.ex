defmodule SampleApp do
  @moduledoc """
  End-to-end demo app for an ILI9488 SPI Display + SD card (FAT) + resistive touch on AtomVM.

  ## What this app demonstrates

  - Driving an ILI9488 in *RGB666 (18-bit)* mode over SPI.
    - The panel is configured for RGB666, but we stream 3 bytes/pixel (RGB888) on the wire.
    - The Display effectively ignores the low 2 bits of each channel, so RGB888 → RGB666 works by truncation.

  - Sharing one physical SPI bus between multiple “devices”:
    - Display (writes, large streams)
    - Touch controller (small command/response reads)
    - SD card (mount + file streaming)
    - `SampleApp.Buses.SPI` acts as the “mutex” so those sequences do not interleave.

  - Blitting raw image files from SD card:
    - We expect a `.RGB` file to be raw RGB888 bytes in row-major order:
      `byte_size == Display.width() * Display.height() * 3`
    - Top-left origin, no header, no compression.

  - Drawing a lightweight clock overlay and visualizing touch input.

  ## Boot sequence (high level)

  1) Start SPI bus owner (`SPI`)
  2) Initialize Display, draw sanity bars
  3) Mount `/sdcard` (FAT)
  4) Find first `.RGB`, validate its byte size, and stream to Display
  5) Start `Clock` (HH:MM:SS)
  6) Start `TouchOverlay` (cursor + `xxx:yyy`)
  7) Start `Touch` reader (sends `{:touch, x, y, z}`)

  ## Notes

  - Pin wiring and SPI host/device config come from `config/config.exs` via `Application.compile_env/2`.
  - All multi-step SPI operations are wrapped in `SPI.transaction/2` to keep bus access serialized.
  """

  @compile {:no_warn_undefined, :gpio}
  @compile {:no_warn_undefined, :atomvm}

  alias SampleApp.{
    Buses.SPI,
    Drivers.Display,
    Drivers.Touch,
    Storage.SDCard,
    UI.Clock,
    UI.TouchOverlay
  }

  # SPI host/device configuration and SDCard chip-select pin come from config at compile time.
  @spi_config Application.compile_env(:sample_app, :spi_config)
  @pin_sd_cs Application.compile_env(:sample_app, :sd_cs_pin)

  # SDCard mount
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
    IO.puts("Starting demo (ILI9488 RGB24 -> RGB666 panel, SD card, touch)")

    {:ok, _} = SPI.start_link(@spi_config)

    # SDCard uses a discrete CS GPIO. We keep it de-selected unless we are actively mounting/reading.
    # This prevents the SD card from responding while we talk to the Display/touch devices.
    :gpio.set_pin_mode(@pin_sd_cs, :output)
    :gpio.digital_write(@pin_sd_cs, :high)

    IO.puts("Booting")

    SPI.transaction(fn spi ->
      IO.puts("Initializing display")
      Display.initialize(spi)
      Display.draw_sanity_bars(spi)

      :io.format(~c"Mounting SD card (root=~s, driver=~s)~n", [@sd_root, @sd_driver])

      case SDCard.mount(spi, @pin_sd_cs, @sd_root, @sd_driver) do
        {:ok, _mref} ->
          SDCard.print_directory(@sd_root)
          blit_first_rgb_or_fallback(spi)

        {:error, reason} ->
          :io.format(~c"SD card mount failed (~p). Using priv/~s~n", [reason, @priv_fallback])
          blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)
      end
    end)

    {:ok, _} = Clock.start_link(h_align: :center, y: 5)
    {:ok, overlay_pid} = TouchOverlay.start_link()
    {:ok, _} = Touch.start_link(notify: self())

    IO.puts("Ready")

    {:ok, %{touch_overlay: overlay_pid}}
  end

  def handle_info({:touch, x, y, z}, state) do
    if is_pid(state.touch_overlay) do
      send(state.touch_overlay, {:touch, x, y, z})
    end

    SPI.transaction(fn spi ->
      Display.draw_touch_dot(spi, x, y)
    end)

    {:noreply, state}
  end

  def handle_info({:touch_up, x, y}, state) do
    if is_pid(state.touch_overlay) do
      send(state.touch_overlay, {:touch_up, x, y})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp blit_first_rgb_or_fallback(spi) do
    :io.format(~c"Looking for .RGB files under ~s~n", [@sd_root])

    case SDCard.first_rgb_file(@sd_root) do
      {:ok, path} ->
        blit_fullscreen_rgb24_from_sd(spi, path)

      :none ->
        :io.format(~c"No .RGB file found. Using priv/~s~n", [@priv_fallback])
        blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)

      {:error, reason} ->
        :io.format(~c"SD card scan failed (~p). Using priv/~s~n", [reason, @priv_fallback])
        blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)
    end
  end

  ## Blit helpers (RGB24 only)

  defp blit_fullscreen_rgb24_from_sd(spi, path) do
    width = Display.width()
    height = Display.height()
    need = Display.fullscreen_rgb24_need_bytes()
    chunk = Display.max_chunk_bytes()

    size =
      case SDCard.file_size(path, chunk) do
        {:ok, s} -> s
        _ -> -1
      end

    if size != need do
      :io.format(~c"Skipping ~s (size ~p, expected ~p)~n", [path, size, need])
      :error
    else
      :io.format(~c"Drawing ~s (~p x ~p)~n", [path, width, height])
      Display.fullscreen_begin_ram_write(spi)
      SDCard.stream_file_chunks(path, chunk, fn bin -> Display.spi_write_chunks(spi, bin) end)
      IO.puts("Done")
      :ok
    end
  end

  defp blit_fullscreen_rgb24_from_priv(spi, priv_app, priv_fallback) do
    width = Display.width()
    height = Display.height()
    need = Display.fullscreen_rgb24_need_bytes()

    case :atomvm.read_priv(priv_app, priv_fallback) do
      bin when is_binary(bin) and byte_size(bin) == need ->
        :io.format(~c"Drawing priv/~s (~p x ~p)~n", [priv_fallback, width, height])
        Display.fullscreen_begin_ram_write(spi)
        Display.spi_write_chunks(spi, bin)
        IO.puts("Done")
        :ok

      bin when is_binary(bin) ->
        :io.format(~c"Skipping priv/~s (size ~p, expected ~p)~n", [
          priv_fallback,
          byte_size(bin),
          need
        ])

        :error

      other ->
        :io.format(~c"Could not read priv/~s (got ~p)~n", [priv_fallback, other])
        :error
    end
  end
end
