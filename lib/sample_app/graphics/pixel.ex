defmodule SampleApp.Graphics.Pixel do
  @moduledoc """
  Small pixel helpers for AtomVM (no heavy image deps).

  - Convert RGB565 little-endian → RGB888 (3 bytes/pixel), with optional R/B swap
  - Infer bytes-per-pixel from file size and pixel count
  """

  import Bitwise

  @type source_channel_order :: :rgb | :bgr

  @doc """
  Convert RGB565 little-endian pixels into RGB888 (3 bytes/pixel).

  `source_order` controls whether the stored data should be interpreted as `:rgb`
  or as `:bgr` (swap red/blue in the output).
  """
  @spec convert_rgb565_le_pixels_to_rgb888(iodata(), source_channel_order()) :: binary()
  def convert_rgb565_le_pixels_to_rgb888(data, source_order \\ :rgb)
      when source_order in [:rgb, :bgr] do
    bin =
      if is_binary(data) do
        data
      else
        :erlang.iolist_to_binary(data)
      end

    convert_rgb565_le_binary_to_rgb888(bin, source_order, [])
  end

  @doc """
  Infer bytes-per-pixel from `size_bytes` and pixel count.
  """
  @spec infer_bytes_per_pixel(non_neg_integer(), non_neg_integer()) :: 2 | 3 | :unknown
  def infer_bytes_per_pixel(size_bytes, pixels)
      when is_integer(size_bytes) and size_bytes >= 0 and is_integer(pixels) and pixels >= 0 do
    cond do
      pixels == 0 -> :unknown
      size_bytes == pixels * 2 -> 2
      size_bytes == pixels * 3 -> 3
      true -> :unknown
    end
  end

  defp convert_rgb565_le_binary_to_rgb888(bin, _source_order, acc) when byte_size(bin) < 2 do
    finalize_iolist(acc)
  end

  defp convert_rgb565_le_binary_to_rgb888(<<lo, hi, rest::binary>>, source_order, acc) do
    {r8, g8, b8} = decode_rgb565_le_pixel_to_rgb888(lo, hi)

    pixel_rgb888 =
      case source_order do
        :bgr -> <<b8, g8, r8>>
        :rgb -> <<r8, g8, b8>>
      end

    convert_rgb565_le_binary_to_rgb888(rest, source_order, [pixel_rgb888 | acc])
  end

  defp finalize_iolist(acc) do
    acc
    |> :lists.reverse()
    |> :erlang.iolist_to_binary()
  end

  defp decode_rgb565_le_pixel_to_rgb888(lo, hi) do
    value16 = lo ||| hi <<< 8

    r5 = value16 >>> 11 &&& 0x1F
    g6 = value16 >>> 5 &&& 0x3F
    b5 = value16 &&& 0x1F

    {
      expand_5bit_channel_to_8bit(r5),
      expand_6bit_channel_to_8bit(g6),
      expand_5bit_channel_to_8bit(b5)
    }
  end

  defp expand_5bit_channel_to_8bit(v5) do
    v5 <<< 3 ||| v5 >>> 2
  end

  defp expand_6bit_channel_to_8bit(v6) do
    v6 <<< 2 ||| v6 >>> 4
  end
end
