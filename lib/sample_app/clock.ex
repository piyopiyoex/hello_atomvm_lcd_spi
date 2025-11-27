defmodule SampleApp.Clock do
  @moduledoc """
  Efficient HH:MM:SS clock with pre-rendered glyphs and partial updates.
  Supports positioning via `at: {x,y}` or `h_align`/`v_align`.
  """

  import Bitwise
  alias SampleApp.LCD
  alias SampleApp.Font

  @scale_x 3
  @scale_y 4
  @gap_x 4
  @padding_y 3

  # Colors (compile-time packed)
  @bg {0x10, 0x10, 0x10}
  @fg {0xF8, 0xF8, 0xF8}
  @bg_bin <<0x10, 0x10, 0x10>>
  @fg_bin <<0xF8, 0xF8, 0xF8>>

  def start_link(spi, opts \\ []) do
    pid = spawn_link(fn -> init(spi, opts) end)
    {:ok, pid}
  end

  def stop(pid), do: send(pid, :stop)

  defp init(spi, opts) do
    :io.format(~c"[clock] starting~n", [])

    {gw8, gh8, _} = Font.glyph(?8)
    cell_w = gw8 * @scale_x
    cell_h = gh8 * @scale_y

    glyphs = pre_render_glyphs(cell_w, cell_h)
    {x0, y0} = resolve_origin(opts, cell_w, cell_h)

    clear_cells(spi, x0, y0, cell_w, cell_h)

    sec = :erlang.system_time(:second)
    chars = to_chars(sec)

    draw_changed_cells(spi, x0, y0, cell_w, cell_h, glyphs, <<>>, chars)
    arm_next_half_tick()

    loop(%{
      spi: spi,
      x0: x0,
      y0: y0,
      cell_w: cell_w,
      cell_h: cell_h,
      glyphs: glyphs,
      last_chars: chars
    })
  end

  defp loop(state) do
    receive do
      :tick ->
        sec = :erlang.system_time(:second)
        chars = to_chars(sec)

        if chars != state.last_chars do
          draw_changed_cells(
            state.spi,
            state.x0,
            state.y0,
            state.cell_w,
            state.cell_h,
            state.glyphs,
            state.last_chars,
            chars
          )
        end

        arm_next_half_tick()
        loop(%{state | last_chars: chars})

      :stop ->
        :ok

      _ ->
        loop(state)
    end
  end

  defp resolve_origin(opts, cell_w, cell_h) do
    sw = LCD.width()
    sh = LCD.height()

    cells = 8
    total_w = cells * cell_w + (cells - 1) * @gap_x
    total_h = cell_h

    case Keyword.get(opts, :at) do
      {x, y} when is_integer(x) and is_integer(y) ->
        {clamp(x, 0, sw - total_w), clamp(y, 0, sh - total_h)}

      _ ->
        hx =
          case Keyword.get(opts, :h_align, :center) do
            :left -> 0
            :right -> sw - total_w
            _center -> div(sw - total_w, 2)
          end

        vy =
          case Keyword.get(opts, :v_align) do
            :center ->
              div(sh - total_h, 2)

            :bottom ->
              sh - total_h

            _ ->
              y = Keyword.get(opts, :y, 20)
              clamp(y, 0, sh - total_h)
          end

        {hx, vy}
    end
  end

  defp clamp(v, min, max) when v < min, do: min
  defp clamp(v, min, max) when v > max, do: max
  defp clamp(v, _min, _max), do: v

  defp arm_next_half_tick() do
    now_us = :erlang.monotonic_time(:microsecond)
    tick_us = 500_000
    next_edge = (div(now_us, tick_us) + 1) * tick_us
    delay_ms = div(next_edge - now_us + 999, 1000)
    :erlang.send_after(delay_ms, self(), :tick)
  end

  defp clear_cells(spi, x0, y0, cw, ch) do
    sw = LCD.width()
    sh = LCD.height()

    cells = 8
    gaps_between = @gap_x * (cells - 1)
    edge_padding = @gap_x * 2
    total_w = cw * cells + gaps_between + edge_padding
    total_h = ch + @padding_y * 2

    ideal_left = x0 - @gap_x
    ideal_top = y0 - @padding_y
    ideal_right = ideal_left + total_w - 1
    ideal_bottom = ideal_top + total_h - 1

    left = max(0, ideal_left)
    top = max(0, ideal_top)
    right = min(sw - 1, ideal_right)
    bottom = min(sh - 1, ideal_bottom)

    width_pixels = right - left + 1
    rows = bottom - top + 1

    LCD.with_lock(fn ->
      LCD.set_window(spi, {left, top}, {right, bottom})
      LCD.begin_ram_write(spi)
      line = :binary.copy(@bg_bin, width_pixels)
      LCD.repeat_rows(spi, line, rows)
    end)
  end

  defp draw_changed_cells(spi, x0, y0, cw, ch, glyphs, prev_chars, new_chars) do
    for idx <- 0..7 do
      prev_ch = char_at(prev_chars, idx)
      curr_ch = char_at(new_chars, idx)

      if curr_ch != prev_ch do
        x = x0 + idx * (cw + @gap_x)
        y = y0

        LCD.with_lock(fn ->
          LCD.set_window(spi, {x, y}, {x + cw - 1, y + ch - 1})
          LCD.begin_ram_write(spi)
          bin = glyph_bin(glyphs, curr_ch)
          LCD.spi_write_chunks(spi, bin)
        end)
      end
    end

    :ok
  end

  defp char_at(<<>>, _i), do: nil
  defp char_at(bin, i) when i < 0 or i >= byte_size(bin), do: nil
  defp char_at(<<h, _::binary>>, 0), do: h
  defp char_at(<<_h, rest::binary>>, i), do: char_at(rest, i - 1)

  defp to_chars(total_s) do
    {h, m, s} = to_hms(total_s)
    <<pad2(h)::binary, ?:, pad2(m)::binary, ?:, pad2(s)::binary>>
  end

  defp to_hms(total_s) do
    day = 86_400
    s = rem(total_s, day)
    s = if s < 0, do: s + day, else: s
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    {h, m, rem(s, 60)}
  end

  defp pad2(n) when n < 10, do: <<?0, ?0 + n>>
  defp pad2(n), do: Integer.to_string(n)

  defp pre_render_glyphs(cell_w, cell_h) do
    g0 = render_cell_centered(?0, cell_w, cell_h)
    g1 = render_cell_centered(?1, cell_w, cell_h)
    g2 = render_cell_centered(?2, cell_w, cell_h)
    g3 = render_cell_centered(?3, cell_w, cell_h)
    g4 = render_cell_centered(?4, cell_w, cell_h)
    g5 = render_cell_centered(?5, cell_w, cell_h)
    g6 = render_cell_centered(?6, cell_w, cell_h)
    g7 = render_cell_centered(?7, cell_w, cell_h)
    g8 = render_cell_centered(?8, cell_w, cell_h)
    g9 = render_cell_centered(?9, cell_w, cell_h)
    colon = render_cell_centered(?:, cell_w, cell_h)

    %{
      ?0 => g0,
      ?1 => g1,
      ?2 => g2,
      ?3 => g3,
      ?4 => g4,
      ?5 => g5,
      ?6 => g6,
      ?7 => g7,
      ?8 => g8,
      ?9 => g9,
      ?: => colon
    }
  end

  defp glyph_bin(glyphs, ch) do
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

  defp render_cell_centered(ch, cell_w, cell_h) do
    {gw, gh, rows} = Font.glyph(ch)
    on_px = :binary.copy(@fg_bin, @scale_x)
    off_px = :binary.copy(@bg_bin, @scale_x)

    row_seg = fn bits -> build_row(bits, gw - 1, on_px, off_px, <<>>) end
    glyph_rows = build_rows(rows, row_seg, gh, [])

    glyph_w_px = gw * @scale_x
    pad_cols = cell_w - glyph_w_px
    left_cols = div(pad_cols, 2)
    right_cols = pad_cols - left_cols
    left_pad = :binary.copy(@bg_bin, left_cols)
    right_pad = :binary.copy(@bg_bin, right_cols)

    build_cell(glyph_rows, left_pad, right_pad, @scale_y, [])
  end

  defp build_row(_bits, col, _on, _off, acc) when col < 0, do: acc

  defp build_row(bits, col, on, off, acc) do
    mask = 1 <<< col
    seg = if (bits &&& mask) != 0, do: on, else: off
    build_row(bits, col - 1, on, off, <<acc::binary, seg::binary>>)
  end

  defp build_rows([], _row_seg, _gh, acc), do: :lists.reverse(acc)

  defp build_rows([bits | rest], row_seg, gh, acc) when gh > 0 do
    seg = row_seg.(bits)
    build_rows(rest, row_seg, gh - 1, [seg | acc])
  end

  defp build_cell([], _left, _right, _scale_y, acc),
    do: IO.iodata_to_binary(:lists.reverse(acc))

  defp build_cell([row | rest], left_pad, right_pad, scale_y, acc) do
    full = <<left_pad::binary, row::binary, right_pad::binary>>
    vseg = :binary.copy(full, scale_y)
    build_cell(rest, left_pad, right_pad, scale_y, [vseg | acc])
  end
end
