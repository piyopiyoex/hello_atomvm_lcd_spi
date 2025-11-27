defmodule SampleApp.FB do
  @moduledoc """
  Tiny RGB buffer for a rectangular region:
    * `new({w,h}, {r,g,b})` allocates an in-RAM region filled with bg
    * `fill_rect/4` draws solid rectangles (clipped)
    * `push/3` sends the region to the LCD at a given screen location

  Pixels are 3 bytes (R,G,B). Designed for small regions (e.g., a clock box).
  """

  alias SampleApp.LCD

  defstruct [:w, :h, :rows]

  @type t :: %__MODULE__{w: pos_integer(), h: pos_integer(), rows: [binary()]}

  @doc "Allocate a region of size `{w,h}` filled with `bg` (RGB tuple)."
  def new({w, h}, {r, g, b}) when w > 0 and h > 0 do
    row = :binary.copy(<<r, g, b>>, w)
    %__MODULE__{w: w, h: h, rows: :lists.duplicate(h, row)}
  end

  @doc """
  Fill a rectangle in the region.
  Arguments are `{x,y}` top-left, `{w,h}` size, and `{r,g,b}` color.
  Coordinates outside the region are clipped; no crash on negatives.
  """
  def fill_rect(%__MODULE__{w: rw, h: rh, rows: rows} = fb, {x, y}, {w, h}, {r, g, b}) do
    # Clip
    x0 = max(x, 0)
    y0 = max(y, 0)
    x1 = min(x + w - 1, rw - 1)
    y1 = min(y + h - 1, rh - 1)

    cond do
      x0 > x1 or y0 > y1 ->
        fb

      true ->
        fill = :binary.copy(<<r, g, b>>, x1 - x0 + 1)
        rows2 = draw_rows(rows, 0, y0, y1, x0, x1, fill, rw)
        %__MODULE__{fb | rows: rows2}
    end
  end

  defp draw_rows([row | rest], idx, y0, y1, x0, x1, fill, rw) do
    [
      maybe_draw_row(row, idx, y0, y1, x0, x1, fill, rw)
      | draw_rows(rest, idx + 1, y0, y1, x0, x1, fill, rw)
    ]
  end

  defp draw_rows([], _idx, _y0, _y1, _x0, _x1, _fill, _rw), do: []

  defp maybe_draw_row(row, idx, y0, y1, x0, x1, fill, rw) do
    if idx >= y0 and idx <= y1 do
      left_bytes = x0 * 3
      mid_bytes = byte_size(fill)
      right_bytes = (rw - 1 - x1) * 3

      <<left::binary-size(left_bytes), _old::binary-size(mid_bytes),
        right::binary-size(right_bytes)>> = row

      <<left::binary, fill::binary, right::binary>>
    else
      row
    end
  end

  @doc """
  Push the region to the panel at screen origin `{sx, sy}`.
  Uses one address-window and streams one row per SPI write.
  """
  def push(spi, %__MODULE__{w: w, h: h, rows: rows}, {sx, sy}) do
    LCD.set_window(spi, {sx, sy}, {sx + w - 1, sy + h - 1})
    LCD.begin_ram_write(spi)
    for row_bin <- rows, do: LCD.spi_write_chunks(spi, row_bin)
    :ok
  end
end
