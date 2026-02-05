defmodule SampleApp.Touch do
  @moduledoc """
  Resistive touch reader for XPT2046/ADS7846-compatible controllers.

  This module polls the touch controller over SPI and:
  - maps raw ADC values into screen coordinates using calibration
  - applies display rotation (0/1/2/3) so touch matches the LCD orientation
  - draws a tiny cursor and an on-screen `xxx:yyy` overlay (OSD)
  - optionally notifies a process with `{:touch, x, y, z}`

  Notes:
  - Touch and LCD share the same physical SPI bus, so reads happen inside
    `SPIBus.transaction/2` to avoid interleaving.
  """

  @compile {:no_warn_undefined, :spi}
  @compile {:no_warn_undefined, :gpio}

  import Bitwise

  alias SampleApp.{Font, LCD, SPIBus}

  @spi_dev :spi_dev_touch

  # XPT2046 control bytes (12-bit, differential)
  @cmd_x 0xD0
  @cmd_y 0x90
  @cmd_z1 0xB0
  @cmd_z2 0xC0

  # Optional PENIRQ (active-low). Set GPIO number if wired; keep nil to poll.
  @pin_irq nil

  # Defaults (can be overridden via start_link opts)
  @default_poll_ms 16
  @default_rotation 0

  # Default calibration window (matches hello_atomvm_scene defaults)
  @default_raw_x_min 80
  @default_raw_x_max 1950
  @default_raw_y_min 80
  @default_raw_y_max 1950

  # Default orientation toggles (pre-rotation)
  @default_swap_xy true
  @default_invert_x true
  @default_invert_y true

  # Pressure threshold (heuristic)
  @min_pressure 50

  # Event throttle / coalesce
  @min_event_interval_us 10_000
  @min_move_px 2

  # EMA smoothing (0..1). 1.0 = no smoothing (most “accurate” feel).
  @default_ema_alpha 1.0

  # Cursor colors (prepacked RGB666-ish)
  @cursor_fg_bin <<0xFC, 0xFC, 0x00>>
  @cursor_bg_bin <<0x00, 0xFC, 0xFC>>
  @cursor_r 3

  # OSD colors
  @osd_bg_bin <<0x10, 0x10, 0x10>>
  @osd_fg_bin <<0xF8, 0xF8, 0xF8>>

  # OSD layout
  @osd_scale_x 2
  @osd_scale_y 3
  @osd_gap 2
  @osd_margin 4
  @osd_cells 7
  @osd_pad_x 4
  @osd_pad_y 3
  @osd_border_rgb {0x30, 0x30, 0x30}

  # Some controllers benefit from discarding the first conversion result after
  # switching channels (command byte).
  @discard_first_conversion true

  ## Public API

  def start_link(opts \\ []) do
    :gen_server.start_link(__MODULE__, opts, [])
  end

  def stop(pid), do: :gen_server.stop(pid)

  @doc """
  Capture raw min/max for `ms` milliseconds. Call while pressing around corners.
  Returns %{xmin: .., xmax: .., ymin: .., ymax: ..}.
  """
  def capture_extremes(ms \\ 3000) do
    case SPIBus.transaction(fn spi -> capture_extremes_on_spi(spi, ms) end, :infinity) do
      {:ok, ex} -> ex
      _ -> %{}
    end
  end

  ## gen_server callbacks

  def init(opts) do
    notify =
      case Keyword.get(opts, :notify) do
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    case @pin_irq do
      nil -> :ok
      pin -> :gpio.set_pin_mode(pin, :input)
    end

    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    rotation = Keyword.get(opts, :rotation, @default_rotation)
    ema_alpha = Keyword.get(opts, :ema_alpha, @default_ema_alpha)

    cal = Keyword.get(opts, :calibration, [])

    raw_x_min = Keyword.get(cal, :raw_x_min, @default_raw_x_min)
    raw_x_max = Keyword.get(cal, :raw_x_max, @default_raw_x_max)
    raw_y_min = Keyword.get(cal, :raw_y_min, @default_raw_y_min)
    raw_y_max = Keyword.get(cal, :raw_y_max, @default_raw_y_max)
    swap_xy = Keyword.get(cal, :swap_xy, @default_swap_xy)
    invert_x = Keyword.get(cal, :invert_x, @default_invert_x)
    invert_y = Keyword.get(cal, :invert_y, @default_invert_y)

    screen_w = LCD.width()
    screen_h = LCD.height()

    {native_w, native_h} =
      if rotation in [1, 3] do
        {screen_h, screen_w}
      else
        {screen_w, screen_h}
      end

    :io.format(~c"[touch] ready (poll=~pms rot=~p ema=~p)~n", [poll_ms, rotation, ema_alpha])

    schedule_poll(poll_ms)

    {:ok,
     %{
       notify: notify,
       poll_ms: poll_ms,
       rotation: rotation,
       ema_alpha: ema_alpha,
       screen_w: screen_w,
       screen_h: screen_h,
       native_w: native_w,
       native_h: native_h,
       cal: %{
         raw_x_min: raw_x_min,
         raw_x_max: raw_x_max,
         raw_y_min: raw_y_min,
         raw_y_max: raw_y_max,
         swap_xy: swap_xy,
         invert_x: invert_x,
         invert_y: invert_y
       },
       last_xy: nil,
       last_ts: nil,
       filt_xy: nil,
       osd: osd_init()
     }}
  end

  def handle_info(:poll, state) do
    {state2, event} =
      case SPIBus.transaction(fn spi -> poll_on_spi(spi, state) end) do
        {:ok, {st, ev}} -> {st, ev}
        _ -> {state, nil}
      end

    if event != nil and state2.notify != nil do
      send(state2.notify, event)
    end

    schedule_poll(state2.poll_ms)
    {:noreply, state2}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp schedule_poll(poll_ms) do
    Process.send_after(self(), :poll, poll_ms)
  end

  defp poll_on_spi(spi, state) do
    # Render initial "000:000" as soon as we have a working SPI transaction.
    state = maybe_draw_initial_osd(spi, state)

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

    if pressed? do
      case read_touch(spi) do
        {:ok, {raw_x, raw_y, z}} ->
          {x0, y0} = to_screen_point(raw_x, raw_y, state)

          {xf, yf} =
            case state.filt_xy do
              {px, py} ->
                a = state.ema_alpha
                {px + a * (x0 - px), py + a * (y0 - py)}

              _ ->
                {x0 * 1.0, y0 * 1.0}
            end

          xi = trunc(xf + 0.5)
          yi = trunc(yf + 0.5)

          draw_cursor(spi, xi, yi, state.last_xy)

          osd2 =
            if moved_enough?(state.last_xy, xi, yi) do
              draw_xy_osd(spi, xi, yi, state.osd)
            else
              state.osd
            end

          {new_last_ts, maybe_event} =
            maybe_event(state.notify, {xi, yi, z}, state.last_ts, state.last_xy)

          state2 = %{
            state
            | last_xy: {xi, yi},
              last_ts: new_last_ts,
              filt_xy: {xf, yf},
              osd: osd2
          }

          {state2, maybe_event}

        :none ->
          maybe_clear_cursor(spi, state.last_xy)
          {%{state | last_xy: nil, filt_xy: nil}, nil}

        {:error, _} ->
          {state, nil}
      end
    else
      maybe_clear_cursor(spi, state.last_xy)
      {%{state | last_xy: nil, filt_xy: nil}, nil}
    end
  end

  defp maybe_draw_initial_osd(spi, %{osd: %{drawn?: false} = osd} = state) do
    osd2 =
      try do
        draw_xy_osd(spi, 0, 0, osd)
      rescue
        _ -> osd
      end

    %{state | osd: osd2}
  end

  defp maybe_draw_initial_osd(_spi, state), do: state

  ## Sampling / averaging

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
    with {:ok, x} <- read12_channel(spi, @cmd_x),
         {:ok, y} <- read12_channel(spi, @cmd_y),
         {:ok, z1} <- read12_channel(spi, @cmd_z1),
         {:ok, z2} <- read12_channel(spi, @cmd_z2) do
      z = z1 + 4095 - z2

      if z < @min_pressure or saturated?(x) or saturated?(y) do
        :none
      else
        {:ok, {x, y, z}}
      end
    else
      _ -> :error
    end
  end

  defp read12_channel(spi, cmd) do
    if @discard_first_conversion do
      _ = read12(spi, cmd)
      read12(spi, cmd)
    else
      read12(spi, cmd)
    end
  end

  # IMPORTANT: XPT2046 returns a 12-bit value left-aligned in the 16-bit payload.
  # We drop the lowest 4 bits (>>> 4). This matches hello_atomvm_scene.
  defp read12(spi, cmd) do
    case :spi.write_read(spi, @spi_dev, %{write_data: <<cmd, 0x00, 0x00>>}) do
      {:ok, <<_::8, hi::8, lo::8>>} ->
        word = hi <<< 8 ||| lo
        {:ok, word >>> 4}

      other ->
        {:error, other}
    end
  end

  defp saturated?(v), do: v == 0 or v == 4095

  defp unzip3([{a, b, c} | t], as, bs, cs), do: unzip3(t, [a | as], [b | bs], [c | cs])
  defp unzip3([], as, bs, cs), do: {:lists.reverse(as), :lists.reverse(bs), :lists.reverse(cs)}

  defp median([]), do: 0

  defp median(list) do
    s = :lists.sort(list)
    n = length(s)
    :lists.nth(div(n, 2) + 1, s)
  end

  ## Raw -> screen mapping (hello_atomvm_scene-style)

  defp to_screen_point(raw_x, raw_y, state) do
    cal = state.cal

    {raw_x, raw_y} =
      if cal.swap_xy do
        {raw_y, raw_x}
      else
        {raw_x, raw_y}
      end

    # 1) scale into native (rotation=0) coordinate space
    x0 = scale(raw_x, cal.raw_x_min, cal.raw_x_max, state.native_w - 1)
    y0 = scale(raw_y, cal.raw_y_min, cal.raw_y_max, state.native_h - 1)

    x0 = if cal.invert_x, do: state.native_w - 1 - x0, else: x0
    y0 = if cal.invert_y, do: state.native_h - 1 - y0, else: y0

    # 2) rotate into screen coordinate space
    apply_rotation({x0, y0}, state.rotation, state.screen_w, state.screen_h)
  end

  defp scale(v, min_v, max_v, max_out) do
    v = clamp(v, min_v, max_v)
    range = max_v - min_v
    if range <= 0, do: 0, else: div((v - min_v) * max_out, range)
  end

  defp clamp(v, min_v, _max_v) when v < min_v, do: min_v
  defp clamp(v, _min_v, max_v) when v > max_v, do: max_v
  defp clamp(v, _min_v, _max_v), do: v

  defp apply_rotation({x, y}, 0, _w, _h), do: {x, y}
  defp apply_rotation({x, y}, 1, w, _h), do: {w - 1 - y, x}
  defp apply_rotation({x, y}, 2, w, h), do: {w - 1 - x, h - 1 - y}
  defp apply_rotation({x, y}, 3, _w, h), do: {y, h - 1 - x}

  ## Cursor drawing

  defp draw_cursor(spi, x, y, prev) do
    maybe_clear_cursor(spi, prev)
    draw_box(spi, x, y, @cursor_fg_bin)
    :ok
  end

  defp maybe_clear_cursor(_spi, nil), do: :ok
  defp maybe_clear_cursor(spi, {x, y}), do: draw_box(spi, x, y, @cursor_bg_bin)

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

    LCD.set_window(spi, {x0, y0}, {x1, y1})
    LCD.begin_ram_write(spi)
    row = :binary.copy(color_bin, bw)
    LCD.repeat_rows(spi, row, bh)
  end

  defp moved_enough?(nil, _x, _y), do: true

  defp moved_enough?({px, py}, x, y) do
    dx = abs(x - px)
    dy = abs(y - py)
    dx >= @min_move_px or dy >= @min_move_px
  end

  ## Eventing

  defp maybe_event(nil, _xyz, last_ts, _last_xy), do: {last_ts, nil}

  defp maybe_event(_pid, {x, y, z}, last_ts, last_xy) do
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
      {now, {:touch, x, y, z}}
    else
      {last_ts, nil}
    end
  end

  ## Optional: extremes capture

  defp capture_extremes_on_spi(spi, ms) do
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

  ## OSD (On-Screen Display) drawing

  defp osd_init() do
    {gw8, gh8, _} = Font.glyph(?8)
    cell_w = gw8 * @osd_scale_x
    cell_h = gh8 * @osd_scale_y

    total_w = @osd_cells * cell_w + (@osd_cells - 1) * @osd_gap + @osd_pad_x * 2
    total_h = cell_h + @osd_pad_y * 2

    avail_x = LCD.width() - total_w
    x0 = if avail_x > 0, do: div(avail_x, 2), else: 0
    y0 = max(0, LCD.height() - total_h - @osd_margin)

    %{
      x0: x0,
      y0: y0,
      cell_w: cell_w,
      cell_h: cell_h,
      total_w: total_w,
      total_h: total_h,
      glyphs: osd_pre_render_glyphs(cell_w, cell_h),
      last_chars: nil,
      drawn?: false
    }
  end

  defp draw_xy_osd(spi, x, y, osd) do
    chars = osd_format_coords(x, y)

    if chars == osd.last_chars do
      osd
    else
      osd2 =
        if osd.drawn? do
          osd
        else
          osd_draw_bar(spi, osd)
          %{osd | drawn?: true}
        end

      prev = osd2.last_chars || <<>>
      osd_draw_changed_cells(spi, osd2, prev, chars)
      %{osd2 | last_chars: chars}
    end
  end

  defp osd_draw_bar(spi, osd) do
    <<r, g, b>> = @osd_bg_bin

    LCD.fill_rect_rgb666(spi, {osd.x0, osd.y0}, {osd.total_w, osd.total_h}, {r, g, b})

    {br, bg, bb} = @osd_border_rgb
    LCD.fill_rect_rgb666(spi, {osd.x0, osd.y0}, {osd.total_w, 1}, {br, bg, bb})
    LCD.fill_rect_rgb666(spi, {osd.x0, osd.y0 + osd.total_h - 1}, {osd.total_w, 1}, {br, bg, bb})
    LCD.fill_rect_rgb666(spi, {osd.x0, osd.y0}, {1, osd.total_h}, {br, bg, bb})
    LCD.fill_rect_rgb666(spi, {osd.x0 + osd.total_w - 1, osd.y0}, {1, osd.total_h}, {br, bg, bb})

    :ok
  end

  defp osd_draw_changed_cells(spi, osd, prev_chars, new_chars) do
    for idx <- 0..(@osd_cells - 1) do
      prev_ch = osd_char_at(prev_chars, idx)
      curr_ch = osd_char_at(new_chars, idx)

      if curr_ch != prev_ch do
        x = osd.x0 + @osd_pad_x + idx * (osd.cell_w + @osd_gap)
        y = osd.y0 + @osd_pad_y

        LCD.set_window(spi, {x, y}, {x + osd.cell_w - 1, y + osd.cell_h - 1})
        LCD.begin_ram_write(spi)
        LCD.spi_write_chunks(spi, osd_glyph_bin(osd.glyphs, curr_ch))
      end
    end

    :ok
  end

  defp osd_char_at(<<>>, _i), do: nil
  defp osd_char_at(bin, i) when i < 0 or i >= byte_size(bin), do: nil
  defp osd_char_at(<<h, _::binary>>, 0), do: h
  defp osd_char_at(<<_h, rest::binary>>, i), do: osd_char_at(rest, i - 1)

  defp osd_format_coords(x, y) do
    <<osd_pad3_bin(x)::binary, ?:, osd_pad3_bin(y)::binary>>
  end

  defp osd_pad3_bin(n) do
    n2 =
      cond do
        n < 0 -> 0
        n > 999 -> 999
        true -> n
      end

    cond do
      n2 < 10 ->
        <<?0, ?0, ?0 + n2>>

      n2 < 100 ->
        tens = div(n2, 10)
        ones = rem(n2, 10)
        <<?0, ?0 + tens, ?0 + ones>>

      true ->
        hundreds = div(n2, 100)
        tens = div(rem(n2, 100), 10)
        ones = rem(n2, 10)
        <<?0 + hundreds, ?0 + tens, ?0 + ones>>
    end
  end

  defp osd_pre_render_glyphs(cell_w, cell_h) do
    %{
      ?0 => osd_render_cell_centered(?0, cell_w, cell_h),
      ?1 => osd_render_cell_centered(?1, cell_w, cell_h),
      ?2 => osd_render_cell_centered(?2, cell_w, cell_h),
      ?3 => osd_render_cell_centered(?3, cell_w, cell_h),
      ?4 => osd_render_cell_centered(?4, cell_w, cell_h),
      ?5 => osd_render_cell_centered(?5, cell_w, cell_h),
      ?6 => osd_render_cell_centered(?6, cell_w, cell_h),
      ?7 => osd_render_cell_centered(?7, cell_w, cell_h),
      ?8 => osd_render_cell_centered(?8, cell_w, cell_h),
      ?9 => osd_render_cell_centered(?9, cell_w, cell_h),
      ?: => osd_render_cell_centered(?:, cell_w, cell_h)
    }
  end

  defp osd_glyph_bin(glyphs, ch) do
    case ch do
      ?0 -> glyphs[?0]
      ?1 -> glyphs[?1]
      ?2 -> glyphs[?2]
      ?3 -> glyphs[?3]
      ?4 -> glyphs[?4]
      ?5 -> glyphs[?5]
      ?6 -> glyphs[?6]
      ?7 -> glyphs[?7]
      ?8 -> glyphs[?8]
      ?9 -> glyphs[?9]
      ?: -> glyphs[?:]
      _ -> glyphs[?0]
    end
  end

  defp osd_render_cell_centered(ch, cell_w, _cell_h) do
    {gw, gh, rows} = Font.glyph(ch)

    on_px = :binary.copy(@osd_fg_bin, @osd_scale_x)
    off_px = :binary.copy(@osd_bg_bin, @osd_scale_x)

    row_seg = fn bits -> osd_build_row(bits, gw - 1, on_px, off_px, <<>>) end
    glyph_rows = osd_build_rows(rows, row_seg, gh, [])

    glyph_w_px = gw * @osd_scale_x
    pad_cols = cell_w - glyph_w_px
    left_cols = div(pad_cols, 2)
    right_cols = pad_cols - left_cols
    left_pad = :binary.copy(@osd_bg_bin, left_cols)
    right_pad = :binary.copy(@osd_bg_bin, right_cols)

    osd_build_cell(glyph_rows, left_pad, right_pad, @osd_scale_y, [])
  end

  defp osd_build_row(_bits, col, _on, _off, acc) when col < 0, do: acc

  defp osd_build_row(bits, col, on, off, acc) do
    mask = 1 <<< col
    seg = if (bits &&& mask) != 0, do: on, else: off
    osd_build_row(bits, col - 1, on, off, <<acc::binary, seg::binary>>)
  end

  defp osd_build_rows([], _row_seg, _gh, acc), do: :lists.reverse(acc)

  defp osd_build_rows([bits | rest], row_seg, gh, acc) when gh > 0 do
    seg = row_seg.(bits)
    osd_build_rows(rest, row_seg, gh - 1, [seg | acc])
  end

  defp osd_build_cell([], _left, _right, _scale_y, acc),
    do: IO.iodata_to_binary(:lists.reverse(acc))

  defp osd_build_cell([row | rest], left_pad, right_pad, scale_y, acc) do
    full = <<left_pad::binary, row::binary, right_pad::binary>>
    vseg = :binary.copy(full, scale_y)
    osd_build_cell(rest, left_pad, right_pad, scale_y, [vseg | acc])
  end
end
