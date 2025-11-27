defmodule SampleApp.Touch do
  @moduledoc """
  XPT2046/ADS7846 touch reader for AtomVM.

  - Shares the SPI bus; uses its own device (:spi_dev_touch) at ~1 MHz, mode 0
  - Optional IRQ pin (active-low). Leave @pin_irq = nil if not wired.
  - Averages samples, maps to screen coords, draws a small cursor box.
  - Emits {:touch, x, y, z} to a `notify:` pid (rate limited + movement threshold).
  - Light EMA smoothing for steadier points.
  - Shows a tiny OSD “x:y” near the bottom-left on movement (fixed width).
  """

  import Bitwise
  alias SampleApp.LCD
  alias SampleApp.Font

  @spi_dev :spi_dev_touch

  # XPT2046 control bytes (12-bit, differential)
  @cmd_y 0x90
  @cmd_x 0xD0
  @cmd_z1 0xB0
  @cmd_z2 0xC0
  # clock 16 bits after command
  @pad <<0x00, 0x00>>

  # Optional PENIRQ (active-low). Set GPIO number if wired; keep nil to poll.
  @pin_irq nil
  # ~60 Hz
  @poll_ms 16

  # Calibration window (adjust to your panel)
  @x_min 300
  @x_max 3700
  @y_min 350
  @y_max 3800

  # Orientation (based on your corner logs)
  @swap_xy true
  @invert_x true
  @invert_y true

  # Canonical color form: prepacked binaries
  @cursor_fg_bin <<0xFC, 0xFC, 0x00>>
  @cursor_bg_bin <<0x00, 0xFC, 0xFC>>

  # Base UI colors for OSD background/foreground (prepacked)
  @osd_bg_bin <<0x10, 0x10, 0x10>>
  @osd_fg_bin <<0xF8, 0xF8, 0xF8>>

  # Dot geometry
  @cursor_r 3

  # Event throttle / coalesce
  # 100 Hz max
  @min_event_interval_us 10_000
  @min_move_px 2

  # EMA smoothing (0..1)
  @ema_alpha 0.35

  # OSD (x:y) rendering ----------------------------------------------------------
  @osd_scale_x 2
  @osd_scale_y 3
  @osd_gap 2
  @osd_margin 4

  # — Public API —

  def start_link(spi, opts \\ []) do
    pid = spawn_link(fn -> init(spi, opts) end)
    {:ok, pid}
  end

  def stop(pid), do: send(pid, :stop)

  # — Internals —

  defp init(spi, opts) do
    notify =
      case Keyword.get(opts, :notify) do
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    case @pin_irq do
      nil -> :ok
      pin -> :gpio.set_pin_mode(pin, :input)
    end

    :io.format(~c"[touch] ready~n", [])
    # last_xy, notify_last_ts, filt_xy (floats)
    loop(spi, nil, notify, nil, nil)
  end

  defp loop(spi, last_xy, notify, last_ts, filt_xy) do
    receive do
      :stop ->
        :ok
    after
      @poll_ms ->
        pressed? =
          case @pin_irq do
            nil ->
              true

            pin ->
              case :gpio.digital_read(pin) do
                :low -> true
                _ -> false
              end
          end

        {new_last_xy, new_last_ts, new_filt} =
          if pressed? do
            case read_touch(spi) do
              {:ok, {rx, ry, z}} ->
                {x, y} = map_to_screen(rx, ry)

                # EMA smoothing (subpixel floats)
                {xf, yf} =
                  case filt_xy do
                    {px, py} -> {px + @ema_alpha * (x - px), py + @ema_alpha * (y - py)}
                    _ -> {x * 1.0, y * 1.0}
                  end

                xi = trunc(xf + 0.5)
                yi = trunc(yf + 0.5)

                draw_cursor(spi, xi, yi, last_xy)

                if moved_enough?(last_xy, xi, yi),
                  do: draw_xy_osd(spi, xi, yi)

                ts2 = maybe_notify(notify, {xi, yi, z}, last_ts, last_xy)
                {{xi, yi}, ts2, {xf, yf}}

              :none ->
                maybe_clear_cursor(spi, last_xy)
                {nil, last_ts, nil}

              {:error, _r} ->
                {last_xy, last_ts, filt_xy}
            end
          else
            maybe_clear_cursor(spi, last_xy)
            {nil, last_ts, nil}
          end

        loop(spi, new_last_xy, notify, new_last_ts, new_filt)
    end
  end

  # --- Sampling / averaging (no Enum) ---

  defp read_touch(spi) do
    samples = collect_samples(spi, 4, [])

    case samples do
      [] ->
        :none

      list ->
        {xs, ys, zs} = unzip3(list, [], [], [])
        {:ok, {median(xs), median(ys), median(zs)}}
    end
  end

  defp collect_samples(_spi, 0, acc), do: acc

  defp collect_samples(spi, n, acc) when n > 0 do
    case sample_once(spi) do
      {:ok, tup} -> collect_samples(spi, n - 1, [tup | acc])
      _ -> collect_samples(spi, n - 1, acc)
    end
  end

  defp sample_once(spi) do
    with {:ok, y} <- read12(spi, @cmd_y),
         {:ok, x} <- read12(spi, @cmd_x),
         {:ok, z1} <- read12(spi, @cmd_z1),
         {:ok, z2} <- read12(spi, @cmd_z2) do
      z = z1 + 4095 - z2

      if z < 50 or saturated?(x) or saturated?(y) do
        :none
      else
        {:ok, {x, y, z}}
      end
    else
      _ -> :error
    end
  end

  # One conversion: send CMD, then clock 16 bits out.
  # Result is left-aligned 12-bit: ((b1<<8) | b2) >> 3, masked to 0x0FFF.
  defp read12(spi, cmd) do
    case :spi.write_read(spi, @spi_dev, %{write_data: <<cmd, @pad::binary>>, read_bits: 24}) do
      {:ok, <<_echo, b1, b2>>} ->
        val = band(bsr(bor(bsl(b1, 8), b2), 3), 0x0FFF)
        {:ok, val}

      other ->
        {:error, other}
    end
  end

  defp saturated?(v), do: v == 0 or v == 4095

  # --- Tiny list helpers ---

  defp unzip3([{a, b, c} | t], as, bs, cs), do: unzip3(t, [a | as], [b | bs], [c | cs])
  defp unzip3([], as, bs, cs), do: {:lists.reverse(as), :lists.reverse(bs), :lists.reverse(cs)}

  defp median([]), do: 0

  defp median(list) do
    s = :lists.sort(list)
    n = length(s)
    # upper median
    :lists.nth(div(n, 2) + 1, s)
  end

  # --- Mapping & cursor drawing ---

  defp map_to_screen(rx, ry) do
    nx = clamp01((rx - @x_min) / max(1, @x_max - @x_min))
    ny = clamp01((ry - @y_min) / max(1, @y_max - @y_min))

    {nx, ny} = if @swap_xy, do: {ny, nx}, else: {nx, ny}
    nx = if @invert_x, do: 1.0 - nx, else: nx
    ny = if @invert_y, do: 1.0 - ny, else: ny

    x = trunc(nx * (LCD.width() - 1))
    y = trunc(ny * (LCD.height() - 1))
    {x, y}
  end

  defp clamp01(v) when v < 0.0, do: 0.0
  defp clamp01(v) when v > 1.0, do: 1.0
  defp clamp01(v), do: v

  defp draw_cursor(spi, x, y, prev) do
    # draw cyan over the old dot
    maybe_clear_cursor(spi, prev)
    # draw yellow at the new position
    draw_box(spi, x, y, @cursor_fg_bin)
    :ok
  end

  defp maybe_clear_cursor(_spi, nil), do: :ok
  defp maybe_clear_cursor(spi, {x, y}), do: draw_box(spi, x, y, @cursor_bg_bin)

  # Accept either prepacked <<r,g,b>> or tuple {r,g,b}; normalize to binary
  defp draw_box(spi, x, y, color) when is_tuple(color) do
    case color do
      {r, g, b} -> draw_box(spi, x, y, <<r, g, b>>)
      _ -> :ok
    end
  end

  defp draw_box(spi, x, y, color_bin) when is_binary(color_bin) do
    rads = @cursor_r
    w = LCD.width()
    h = LCD.height()
    x0 = max(0, x - rads)
    y0 = max(0, y - rads)
    x1 = min(w - 1, x + rads)
    y1 = min(h - 1, y + rads)

    bw = x1 - x0 + 1
    bh = y1 - y0 + 1

    # Single critical section
    LCD.with_lock(fn ->
      LCD.set_window(spi, {x0, y0}, {x1, y1})
      LCD.begin_ram_write(spi)
      row = :binary.copy(color_bin, bw)
      LCD.repeat_rows(spi, row, bh)
    end)
  end

  defp moved_enough?(nil, _x, _y), do: true

  defp moved_enough?({px, py}, x, y) do
    dx = if x >= px, do: x - px, else: px - x
    dy = if y >= py, do: y - py, else: py - y
    dx >= @min_move_px or dy >= @min_move_px
  end

  # --- Eventing ---

  defp maybe_notify(nil, _xyz, last_ts, _last_xy), do: last_ts

  defp maybe_notify(pid, {x, y, z}, last_ts, last_xy) do
    now = :erlang.monotonic_time(:microsecond)
    ok_by_time = last_ts == nil or now - last_ts >= @min_event_interval_us

    ok_by_move =
      case last_xy do
        {px, py} ->
          dx = abs(x - px)
          dy = abs(y - py)
          dx >= @min_move_px or dy >= @min_move_px

        _ ->
          true
      end

    if ok_by_time or ok_by_move do
      send(pid, {:touch, x, y, z})
      now
    else
      last_ts
    end
  end

  # --- Optional: quick raw extremes capture for calibration ----------------------

  @doc """
  Capture raw min/max for ~`ms` milliseconds. Call while pressing around corners.
  Returns %{xmin: .., xmax: .., ymin: .., ymax: ..}.
  """
  def capture_extremes(spi, ms \\ 3000) do
    t0 = :erlang.monotonic_time(:millisecond)

    loop = fn loop, ex ->
      now = :erlang.monotonic_time(:millisecond)

      if now - t0 > ms do
        ex
      else
        case read_touch(spi) do
          {:ok, {rx, ry, _z}} ->
            ex2 = %{
              xmin: min(map_get(ex, :xmin, 4095), rx),
              xmax: max(map_get(ex, :xmax, 0), rx),
              ymin: min(map_get(ex, :ymin, 4095), ry),
              ymax: max(map_get(ex, :ymax, 0), ry)
            }

            loop.(loop, ex2)

          _ ->
            loop.(loop, ex)
        end
      end
    end

    loop.(loop, %{})
  end

  defp map_get(map, key, default) do
    case :maps.find(key, map) do
      {:ok, v} -> v
      _ -> default
    end
  end

  # ====================== OSD (x:y) drawing =====================================

  defp draw_xy_osd(spi, x, y) do
    # fixed-width text like the clock: always "xxx:yyy"
    text = pad3(x) ++ [?:] ++ pad3(y)

    # Pre-render each glyph to a cell binary (scaled).
    glyphs = render_text_cells(text, [])

    case glyphs do
      [] ->
        :ok

      list ->
        # Constant bar size from "479:319"
        {bar_w, bar_h} = osd_max_dims()

        x0 = @osd_margin
        y0 = LCD.height() - bar_h - @osd_margin

        LCD.with_lock(fn ->
          # Clear the whole fixed bar area
          LCD.set_window(spi, {x0 - 1, y0 - 1}, {x0 + bar_w, y0 + bar_h})
          LCD.begin_ram_write(spi)
          clear_row = :binary.copy(@osd_bg_bin, bar_w + 2)
          for _ <- 1..(bar_h + 2), do: LCD.spi_write_chunks(spi, clear_row)

          # Draw current text, left-aligned within the bar
          draw_cells(spi, list, x0, y0)
        end)
    end
  end

  # pad integer to exactly 3 chars ('000'..'999') as charlist
  defp pad3(n) do
    n2 = if n < 0, do: 0, else: if(n > 999, do: 999, else: n)
    s = :erlang.integer_to_list(n2)

    case length(s) do
      1 -> [?0, ?0 | s]
      2 -> [?0 | s]
      _ -> s
    end
  end

  defp render_text_cells([ch | rest], acc) do
    {w, h, bin} = glyph_cell_bin(ch)
    render_text_cells(rest, [{w, h, bin} | acc])
  end

  defp render_text_cells([], acc), do: :lists.reverse(acc)

  defp text_dims([{w, h, _bin} | rest]) do
    {sum_w(rest, w), h}
  end

  defp text_dims([]), do: {0, 0}

  defp sum_w([{w, _h, _} | t], acc), do: sum_w(t, acc + w + @osd_gap)
  # remove last gap
  defp sum_w([], acc), do: acc - @osd_gap

  defp draw_cells(_spi, [], _x, _y), do: :ok

  defp draw_cells(spi, [{w, h, bin} | rest], x, y) do
    LCD.set_window(spi, {x, y}, {x + w - 1, y + h - 1})
    LCD.begin_ram_write(spi)
    LCD.spi_write_chunks(spi, bin)
    draw_cells(spi, rest, x + w + @osd_gap, y)
  end

  # Turn a Font.glyph into a scaled RGB cell binary
  defp glyph_cell_bin(ch) do
    {gw, gh, rows} = Font.glyph(ch)
    on_px = :binary.copy(@osd_fg_bin, @osd_scale_x)
    off_px = :binary.copy(@osd_bg_bin, @osd_scale_x)
    w = gw * @osd_scale_x
    h = gh * @osd_scale_y

    bin = build_rows(rows, gw - 1, on_px, off_px, gh, [])
    {w, h, bin}
  end

  # Build all rows (scaled) into a single binary
  defp build_rows([bits | rest], col_max, on, off, gh, acc) when gh > 0 do
    row = build_row_bits(bits, col_max, on, off, <<>>)
    vseg = :binary.copy(row, @osd_scale_y)
    build_rows(rest, col_max, on, off, gh - 1, [vseg | acc])
  end

  defp build_rows([], _cm, _on, _off, _gh, acc),
    do: IO.iodata_to_binary(:lists.reverse(acc))

  # Build a single glyph row, left→right (MSB first), scaled horizontally
  defp build_row_bits(_bits, col, _on, _off, acc) when col < 0, do: acc

  defp build_row_bits(bits, col, on, off, acc) do
    mask = 1 <<< col
    seg = if (bits &&& mask) != 0, do: on, else: off
    build_row_bits(bits, col - 1, on, off, <<acc::binary, seg::binary>>)
  end

  defp osd_max_text() do
    Integer.to_charlist(LCD.width() - 1) ++ [?:] ++ Integer.to_charlist(LCD.height() - 1)
  end

  defp osd_max_dims() do
    cells = render_text_cells(osd_max_text(), [])
    text_dims(cells)
  end
end
