defmodule SampleApp.UI.Font5x7 do
  @moduledoc """
  Minimal 5x7 monospace bitmap font (digits + colon) for AtomVM.
  """

  import Bitwise

  @w 5
  @h 7

  @type glyph_row :: non_neg_integer()
  @type glyph_rows :: [glyph_row()]
  @type glyph :: {width :: 1..5, height :: 7, glyph_rows()}
  @type rgb888_pixel :: <<_::24>>
  @type rgb888_cell :: binary()
  @type glyph_map :: %{required(integer()) => rgb888_cell()}

  @doc """
  Fetch the glyph bitmap for a codepoint.
  """
  @spec glyph(integer()) :: glyph()
  def glyph(?0),
    do:
      {@w, @h,
       [
         0b01110,
         0b10001,
         0b10001,
         0b10001,
         0b10001,
         0b10001,
         0b01110
       ]}

  def glyph(?1),
    do:
      {@w, @h,
       [
         0b00100,
         0b01100,
         0b00100,
         0b00100,
         0b00100,
         0b00100,
         0b01110
       ]}

  def glyph(?2),
    do:
      {@w, @h,
       [
         0b01110,
         0b10001,
         0b00001,
         0b00010,
         0b00100,
         0b01000,
         0b11111
       ]}

  def glyph(?3),
    do:
      {@w, @h,
       [
         0b11110,
         0b00001,
         0b00001,
         0b01110,
         0b00001,
         0b00001,
         0b11110
       ]}

  def glyph(?4),
    do:
      {@w, @h,
       [
         0b00010,
         0b00110,
         0b01010,
         0b10010,
         0b11111,
         0b00010,
         0b00010
       ]}

  def glyph(?5),
    do:
      {@w, @h,
       [
         0b11111,
         0b10000,
         0b11110,
         0b00001,
         0b00001,
         0b10001,
         0b01110
       ]}

  def glyph(?6),
    do:
      {@w, @h,
       [
         0b00110,
         0b01000,
         0b10000,
         0b11110,
         0b10001,
         0b10001,
         0b01110
       ]}

  def glyph(?7),
    do:
      {@w, @h,
       [
         0b11111,
         0b00001,
         0b00010,
         0b00100,
         0b01000,
         0b01000,
         0b01000
       ]}

  def glyph(?8),
    do:
      {@w, @h,
       [
         0b01110,
         0b10001,
         0b10001,
         0b01110,
         0b10001,
         0b10001,
         0b01110
       ]}

  def glyph(?9),
    do:
      {@w, @h,
       [
         0b01110,
         0b10001,
         0b10001,
         0b01111,
         0b00001,
         0b00010,
         0b01100
       ]}

  def glyph(?:),
    do:
      {1, @h,
       [
         0b0,
         0b1,
         0b0,
         0b0,
         0b1,
         0b0,
         0b0
       ]}

  def glyph(_), do: {@w, @h, [0, 0, 0, 0, 0, 0, 0]}

  @doc """
  Return the font height in pixels.
  """
  @spec height() :: pos_integer()
  def height(), do: @h

  @doc """
  Rasterize multiple glyphs into RGB888 cell binaries.
  """
  @spec rasterize_glyphs(
          [integer()],
          pos_integer(),
          pos_integer(),
          pos_integer(),
          rgb888_pixel(),
          rgb888_pixel()
        ) :: glyph_map()
  def rasterize_glyphs(chars, cell_w, scale_x, scale_y, fg_bin, bg_bin)
      when is_list(chars) and cell_w > 0 and scale_x > 0 and scale_y > 0 and is_binary(fg_bin) and
             is_binary(bg_bin) do
    for ch <- chars, into: %{} do
      {ch, rasterize_cell_centered(ch, cell_w, scale_x, scale_y, fg_bin, bg_bin)}
    end
  end

  @doc """
  Rasterize a single glyph into an RGB888 cell binary.
  """
  @spec rasterize_cell_centered(
          integer(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          rgb888_pixel(),
          rgb888_pixel()
        ) :: rgb888_cell()
  def rasterize_cell_centered(ch, cell_w, scale_x, scale_y, fg_bin, bg_bin)
      when cell_w > 0 and scale_x > 0 and scale_y > 0 and is_binary(fg_bin) and is_binary(bg_bin) do
    {gw, gh, rows} = glyph(ch)

    on_px = :binary.copy(fg_bin, scale_x)
    off_px = :binary.copy(bg_bin, scale_x)

    row_seg = fn bits -> build_row(bits, gw - 1, on_px, off_px, <<>>) end
    glyph_rows = build_rows(rows, row_seg, gh, [])

    glyph_w_px = gw * scale_x
    pad_cols = cell_w - glyph_w_px
    left_cols = if pad_cols > 0, do: div(pad_cols, 2), else: 0
    right_cols = if pad_cols > 0, do: pad_cols - left_cols, else: 0

    left_pad = :binary.copy(bg_bin, left_cols)
    right_pad = :binary.copy(bg_bin, right_cols)

    build_cell(glyph_rows, left_pad, right_pad, scale_y, [])
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
