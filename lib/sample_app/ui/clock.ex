defmodule SampleApp.UI.Clock do
  @moduledoc """
  Small, allocation-conscious HH:MM:SS clock renderer.

  - Pre-renders glyph cells (digits + colon) once at init
  - On each tick, only redraws the cells that changed
  - Wraps each update in a single `SPI.transaction/1` for shared-bus politeness

  ## Pixel format note

  The Display is configured for RGB666, but we stream RGB888 bytes.
  The panel truncates low bits, so binaries are still 3 bytes/pixel.
  """

  alias SampleApp.{
    Buses.SPI,
    Drivers.Display,
    UI.Font5x7
  }

  @scale_x 3
  @scale_y 4
  @gap_x 4
  @padding_y 3

  @clock_chars ~c"0123456789:"

  # Colors (compile-time packed)
  @bg_bin <<0x10, 0x10, 0x10>>
  @fg_bin <<0xF8, 0xF8, 0xF8>>

  @type h_align :: :left | :center | :right
  @type v_align :: :top | :center | :bottom

  @type start_opt ::
          {:at, {integer(), integer()}}
          | {:h_align, h_align()}
          | {:v_align, v_align()}
          | {:y, integer()}

  @type start_opts :: [start_opt()]

  ## Public API

  @doc """
  Start the clock renderer.
  """
  @spec start_link(start_opts()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    :gen_server.start_link(__MODULE__, opts, [])
  end

  @doc """
  Stop the clock renderer.
  """
  @spec stop(pid()) :: :ok
  def stop(pid), do: :gen_server.stop(pid)

  ## gen_server callbacks

  def init(opts) do
    :io.format(~c"[clock] starting~n", [])

    {gw8, gh8, _} = Font5x7.glyph(?8)
    cell_w = gw8 * @scale_x
    cell_h = gh8 * @scale_y

    glyphs = Font5x7.rasterize_glyphs(@clock_chars, cell_w, @scale_x, @scale_y, @fg_bin, @bg_bin)

    {x0, y0} = resolve_origin(opts, cell_w, cell_h)

    sec = :erlang.system_time(:second)
    chars = to_chars(sec)

    SPI.transaction(fn spi ->
      clear_cells(spi, x0, y0, cell_w, cell_h)
      draw_changed_cells(spi, x0, y0, cell_w, cell_h, glyphs, <<>>, chars)
    end)

    arm_next_half_tick()

    {:ok,
     %{
       x0: x0,
       y0: y0,
       cell_w: cell_w,
       cell_h: cell_h,
       glyphs: glyphs,
       last_chars: chars
     }}
  end

  def handle_info(:tick, state) do
    sec = :erlang.system_time(:second)
    chars = to_chars(sec)

    state2 =
      if chars != state.last_chars do
        SPI.transaction(fn spi ->
          draw_changed_cells(
            spi,
            state.x0,
            state.y0,
            state.cell_w,
            state.cell_h,
            state.glyphs,
            state.last_chars,
            chars
          )
        end)

        %{state | last_chars: chars}
      else
        state
      end

    arm_next_half_tick()
    {:noreply, state2}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp resolve_origin(opts, cell_w, cell_h) do
    sw = Display.width()
    sh = Display.height()

    # "HH:MM:SS" is 8 characters (including two colons).
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

  defp clamp(v, min, _max) when v < min, do: min
  defp clamp(v, _min, max) when v > max, do: max
  defp clamp(v, _min, _max), do: v

  # Align ticks to the next 500ms boundary using monotonic time.
  defp arm_next_half_tick() do
    now_us = :erlang.monotonic_time(:microsecond)
    tick_us = 500_000
    next_edge = (div(now_us, tick_us) + 1) * tick_us
    delay_ms = div(next_edge - now_us + 999, 1000)
    :erlang.send_after(delay_ms, self(), :tick)
  end

  defp clear_cells(spi, x0, y0, cw, ch) do
    sw = Display.width()
    sh = Display.height()

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

    Display.set_window(spi, {left, top}, {right, bottom})
    Display.begin_ram_write(spi)
    line = :binary.copy(@bg_bin, width_pixels)
    Display.repeat_rows(spi, line, rows)
  end

  defp draw_changed_cells(spi, x0, y0, cw, ch, glyphs, prev_chars, new_chars) do
    for idx <- 0..7 do
      prev_ch = char_at(prev_chars, idx)
      curr_ch = char_at(new_chars, idx)

      if curr_ch != prev_ch do
        x = x0 + idx * (cw + @gap_x)
        y = y0

        Display.set_window(spi, {x, y}, {x + cw - 1, y + ch - 1})
        Display.begin_ram_write(spi)
        Display.spi_write_chunks(spi, Map.get(glyphs, curr_ch, glyphs[?0]))
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
end
