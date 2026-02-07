defmodule SampleApp.Drivers.Display do
  @moduledoc """
  ILI9488 SPI display helpers for AtomVM.

  - No internal locking: callers must wrap multi-step operations in `SampleApp.Buses.SPI.transaction/2`.
  - Panel runs RGB666; we send RGB888 (3 bytes/pixel) and the panel truncates low bits.
  - Large writes are chunked (`@max_chunk_bytes`, ~4KiB-aligned fills) for reliability/performance.
  """

  # AtomVM provides these modules at runtime (host BEAM does not).
  @compile {:no_warn_undefined, :spi}
  @compile {:no_warn_undefined, :gpio}

  import Bitwise

  # Display geometry
  @screen_w 480
  @screen_h 320
  def width(), do: @screen_w
  def height(), do: @screen_h

  # Maximum safe single write size (bytes) for the SPI driver on this target.
  # Empirically, sizes around 4096 can trigger driver errors (e.g. "258").
  # Keeping it slightly under 4KiB is a boring but reliable choice.
  @max_chunk_bytes 4092
  def max_chunk_bytes(), do: @max_chunk_bytes

  # SPI device name
  @spi_dev :spi_dev_display

  # Control pins (board silkscreen → ESP32 GPIO).
  # These are not SPI “device CS” pins; they are panel control signals (D/C, RESET).
  # D2: D/C
  @pin_dc 3
  # D1: RESET
  @pin_rst 2

  # MIPI DCS subset
  @cmd_slpout 0x11
  @cmd_noron 0x13
  @cmd_dispon 0x29
  @cmd_madctl 0x36
  @cmd_pixfmt 0x3A
  @cmd_caset 0x2A
  @cmd_paset 0x2B
  @cmd_ramwr 0x2C
  @cmd_invon 0x21
  @cmd_invoff 0x20

  # Orientation + pixel format
  @madctl_landscape_bgr 0x28
  # 18-bit; 3 bytes/pixel on the wire
  @pixfmt_rgb666 0x66

  # Chunking for solid fills (~4 KiB; multiple of 12 for RGB666 + DMA)
  @bpp 3
  @dma_align 4
  @target 4 * 1024
  @spi_chunk_bytes @target - rem(@target, @bpp * @dma_align)
  @spi_chunk_px div(@spi_chunk_bytes, @bpp)

  ## Public API

  def initialize(spi) do
    :gpio.set_pin_mode(@pin_dc, :output)
    :gpio.set_pin_mode(@pin_rst, :output)

    hw_reset()

    send_command(spi, @cmd_slpout)
    Process.sleep(150)
    send_command(spi, @cmd_noron)
    Process.sleep(10)
    send_command(spi, @cmd_madctl)
    send_data(spi, <<@madctl_landscape_bgr>>)
    send_command(spi, @cmd_pixfmt)
    send_data(spi, <<@pixfmt_rgb666>>)
    send_command(spi, @cmd_dispon)
    Process.sleep(20)

    send_command(spi, @cmd_invon)
    Process.sleep(120)
    send_command(spi, @cmd_invoff)
    Process.sleep(120)
    :ok
  end

  def draw_sanity_bars(spi) do
    w = width()
    h = height()

    bar_w = div(w, 3)
    x0 = 0
    x1 = bar_w
    x2 = bar_w * 2

    fill_rect_rgb666(spi, {x0, 0}, {bar_w, h}, rgb888_to_rgb666(255, 0, 0))
    fill_rect_rgb666(spi, {x1, 0}, {bar_w, h}, rgb888_to_rgb666(0, 255, 0))
    fill_rect_rgb666(spi, {x2, 0}, {w - x2, h}, rgb888_to_rgb666(0, 0, 255))
    :ok
  end

  @doc "Mask RGB888 to panel's RGB666 (each channel rounded down to multiples of 4)."
  def rgb888_to_rgb666(r8, g8, b8), do: {r8 &&& 0xFC, g8 &&& 0xFC, b8 &&& 0xFC}

  @doc "Fill a rectangle with a solid RGB666-ish color (RGB888 on wire)."
  def fill_rect_rgb666(spi, {x, y}, {w, h}, {r, g, b}) do
    set_window(spi, {x, y}, {x + w - 1, y + h - 1})

    total_px = w * h
    chunk_px = @spi_chunk_px
    chunk = :binary.copy(<<r, g, b>>, chunk_px)

    begin_ram_write(spi)

    full = div(total_px, chunk_px)
    remp = rem(total_px, chunk_px)

    for _ <- 1..full do
      :ok = :spi.write(spi, @spi_dev, %{write_data: chunk})
    end

    if remp > 0 do
      :ok = :spi.write(spi, @spi_dev, %{write_data: :binary.copy(<<r, g, b>>, remp)})
    end

    :ok
  end

  def set_window(spi, {x0, y0}, {x1, y1}) do
    send_command(spi, @cmd_caset)
    send_data(spi, <<x0::16-big, x1::16-big>>)
    send_command(spi, @cmd_paset)
    send_data(spi, <<y0::16-big, y1::16-big>>)
    :ok
  end

  def begin_ram_write(spi) do
    send_command(spi, @cmd_ramwr)
    set_dc_for_data()
    :ok
  end

  @doc "Stream a binary to the display in chunks (<= @max_chunk_bytes)."
  def spi_write_chunks(spi, bin) when is_binary(bin) do
    write_loop(spi, bin, @max_chunk_bytes)
  end

  @doc "Write the same row binary `rows` times."
  def repeat_rows(spi, row_bin, rows) when is_integer(rows) and rows > 0 do
    for _ <- 1..rows, do: spi_write_chunks(spi, row_bin)
    :ok
  end

  def repeat_rows(_spi, _row_bin, _rows), do: :ok

  def clear_screen(spi, {r, g, b}) do
    w = width()
    h = height()
    set_window(spi, {0, 0}, {w - 1, h - 1})
    begin_ram_write(spi)
    line = :binary.copy(<<r, g, b>>, w)
    repeat_rows(spi, line, h)
    :ok
  end

  @doc """
  Expected bytes for a fullscreen raw RGB24 (RGB888) frame.
  """
  def fullscreen_rgb24_need_bytes() do
    width() * height() * 3
  end

  @doc """
  Prepare the display for a fullscreen RAM write (RGB24 stream).
  """
  def fullscreen_begin_ram_write(spi) do
    w = width()
    h = height()
    set_window(spi, {0, 0}, {w - 1, h - 1})
    begin_ram_write(spi)
    :ok
  end

  @doc """
  Draw a tiny touch feedback dot near `{x, y}`.
  Clamps to screen bounds.
  """
  def draw_touch_dot(spi, x, y, {r, g, b} \\ {0x00, 0xFC, 0x00})
      when is_integer(x) and is_integer(y) do
    x0 = max(x - 1, 0)
    y0 = max(y - 1, 0)
    x1 = min(x + 1, width() - 1)
    y1 = min(y + 1, height() - 1)

    fill_rect_rgb666(spi, {x0, y0}, {x1 - x0 + 1, y1 - y0 + 1}, {r, g, b})
  end

  ## Internals

  defp send_command(spi, byte) when is_integer(byte) and byte in 0..255 do
    set_dc_for_command()
    :ok = :spi.write(spi, @spi_dev, %{write_data: <<byte>>})
  end

  defp send_data(spi, bin) when is_binary(bin) do
    set_dc_for_data()
    :ok = :spi.write(spi, @spi_dev, %{write_data: bin})
  end

  defp set_dc_for_command(), do: :gpio.digital_write(@pin_dc, :low)
  defp set_dc_for_data(), do: :gpio.digital_write(@pin_dc, :high)

  defp hw_reset() do
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(10)
    :gpio.digital_write(@pin_rst, :low)
    Process.sleep(80)
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(150)
  end

  defp write_loop(_spi, <<>>, _max), do: :ok

  defp write_loop(spi, bin, max) do
    size = byte_size(bin)

    if size <= max do
      :ok = :spi.write(spi, @spi_dev, %{write_data: bin})
      :ok
    else
      head = :binary.part(bin, 0, max)
      tail = :binary.part(bin, max, size - max)
      :ok = :spi.write(spi, @spi_dev, %{write_data: head})
      write_loop(spi, tail, max)
    end
  end
end
