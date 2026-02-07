defmodule SampleApp.UI.TouchOverlay do
  @moduledoc """
  Minimal touch visualization overlay:

  - Draws a small cursor box at the latest touch point
  - Draws an on-screen `xxx:yyy` readout near the bottom
  - Uses `SPI.transaction/2` for shared-bus politeness
  """

  alias SampleApp.{
    Buses.SPI,
    Drivers.Display,
    UI.Font5x7,
    UI.TouchOverlay.OSD
  }

  # Cursor colors (RGB888 on wire; panel truncates to RGB666)
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

  # When to redraw OSD
  @min_move_px 2

  # Boot-time initial draw retry (SPI timing can vary)
  @initial_draw_retry_ms 50
  @initial_draw_max_attempts 20

  @osd_chars ~c"0123456789:"

  ## Public API

  def start_link(opts \\ []) do
    :gen_server.start_link(__MODULE__, opts, [])
  end

  ## gen_server

  def init(_opts) do
    osd = osd_init()

    # Render "000:000" once on boot, even before any touch events.
    send(self(), :render_initial)

    {:ok, %{last_xy: nil, osd: osd, initial_draw_attempts: 0}}
  end

  def handle_info(:render_initial, state) do
    # Force a fresh draw regardless of cached last_chars/drawn? state.
    osd0 = %OSD{state.osd | last_chars: nil, drawn?: false}

    case SPI.transaction(fn spi -> draw_xy_osd(spi, 0, 0, osd0) end) do
      {:ok, osd2} ->
        {:noreply, %{state | osd: osd2}}

      _ ->
        attempts = state.initial_draw_attempts + 1

        if attempts < @initial_draw_max_attempts do
          Process.send_after(self(), :render_initial, @initial_draw_retry_ms)
        end

        {:noreply, %{state | initial_draw_attempts: attempts}}
    end
  end

  def handle_info({:touch, x, y, _z}, state) do
    state2 =
      case SPI.transaction(fn spi -> render_touch(spi, x, y, state) end) do
        {:ok, st} -> st
        _ -> state
      end

    {:noreply, state2}
  end

  def handle_info({:touch_up, _x, _y}, state) do
    state2 =
      case SPI.transaction(fn spi -> clear_cursor(spi, state) end) do
        {:ok, st} -> st
        _ -> state
      end

    {:noreply, state2}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Rendering

  defp render_touch(spi, x, y, state) do
    state = draw_cursor(spi, x, y, state)

    osd2 =
      if moved_enough?(state.last_xy, x, y) do
        draw_xy_osd(spi, x, y, state.osd)
      else
        state.osd
      end

    %{state | last_xy: {x, y}, osd: osd2}
  end

  defp clear_cursor(_spi, %{last_xy: nil} = state), do: state

  defp clear_cursor(spi, %{last_xy: {x, y}} = state) do
    draw_box(spi, x, y, @cursor_bg_bin)
    %{state | last_xy: nil}
  end

  defp draw_cursor(spi, x, y, %{last_xy: nil} = state) do
    draw_box(spi, x, y, @cursor_fg_bin)
    state
  end

  defp draw_cursor(spi, x, y, state) do
    state = clear_cursor(spi, state)
    draw_box(spi, x, y, @cursor_fg_bin)
    state
  end

  defp draw_box(spi, x, y, color_bin) when is_binary(color_bin) do
    rads = @cursor_r
    w = Display.width()
    h = Display.height()

    x0 = max(0, x - rads)
    y0 = max(0, y - rads)
    x1 = min(w - 1, x + rads)
    y1 = min(h - 1, y + rads)

    bw = x1 - x0 + 1
    bh = y1 - y0 + 1

    Display.set_window(spi, {x0, y0}, {x1, y1})
    Display.begin_ram_write(spi)

    row = :binary.copy(color_bin, bw)
    Display.repeat_rows(spi, row, bh)
  end

  defp moved_enough?(nil, _x, _y), do: true

  defp moved_enough?({px, py}, x, y) do
    dx = abs(x - px)
    dy = abs(y - py)
    dx >= @min_move_px or dy >= @min_move_px
  end

  ## OSD

  defp osd_init() do
    {gw8, gh8, _} = Font5x7.glyph(?8)
    cell_w = gw8 * @osd_scale_x
    cell_h = gh8 * @osd_scale_y

    total_w = @osd_cells * cell_w + (@osd_cells - 1) * @osd_gap + @osd_pad_x * 2
    total_h = cell_h + @osd_pad_y * 2

    avail_x = Display.width() - total_w
    x0 = if avail_x > 0, do: div(avail_x, 2), else: 0
    y0 = max(0, Display.height() - total_h - @osd_margin)

    glyphs =
      Font5x7.rasterize_glyphs(
        @osd_chars,
        cell_w,
        @osd_scale_x,
        @osd_scale_y,
        @osd_fg_bin,
        @osd_bg_bin
      )

    %OSD{
      x0: x0,
      y0: y0,
      cell_w: cell_w,
      cell_h: cell_h,
      total_w: total_w,
      total_h: total_h,
      glyphs: glyphs,
      last_chars: nil,
      drawn?: false
    }
  end

  defp draw_xy_osd(spi, x, y, %OSD{} = osd) do
    chars = osd_format_coords(x, y)

    if chars == osd.last_chars do
      osd
    else
      osd2 =
        if osd.drawn? do
          osd
        else
          osd_draw_bar(spi, osd)
          %OSD{osd | drawn?: true}
        end

      prev = osd2.last_chars || <<>>
      osd_draw_changed_cells(spi, osd2, prev, chars)
      %OSD{osd2 | last_chars: chars}
    end
  end

  defp osd_draw_bar(spi, %OSD{x0: x, y0: y, total_w: w, total_h: h}) do
    # Background
    <<r, g, b>> = @osd_bg_bin
    Display.fill_rect_rgb666(spi, {x, y}, {w, h}, {r, g, b})

    # Border
    {br, bg, bb} = @osd_border_rgb
    border = {br, bg, bb}

    # top, bottom
    Display.fill_rect_rgb666(spi, {x, y}, {w, 1}, border)
    Display.fill_rect_rgb666(spi, {x, y + h - 1}, {w, 1}, border)

    # left, right
    Display.fill_rect_rgb666(spi, {x, y}, {1, h}, border)
    Display.fill_rect_rgb666(spi, {x + w - 1, y}, {1, h}, border)

    :ok
  end

  defp osd_draw_changed_cells(spi, %OSD{} = osd, prev_chars, new_chars) do
    for idx <- 0..(@osd_cells - 1) do
      prev_ch = osd_char_at(prev_chars, idx)
      curr_ch = osd_char_at(new_chars, idx)

      if curr_ch != prev_ch do
        {x, y} = osd_cell_origin(osd, idx)

        Display.set_window(spi, {x, y}, {x + osd.cell_w - 1, y + osd.cell_h - 1})
        Display.begin_ram_write(spi)

        glyph_bin = osd.glyphs[curr_ch] || osd.glyphs[?0]
        Display.spi_write_chunks(spi, glyph_bin)
      end
    end

    :ok
  end

  defp osd_cell_origin(%OSD{} = osd, idx) do
    x = osd.x0 + @osd_pad_x + idx * (osd.cell_w + @osd_gap)
    y = osd.y0 + @osd_pad_y
    {x, y}
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
end
