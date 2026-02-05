defmodule SampleApp.Font do
  @moduledoc """
  Minimal 5x7 monospace bitmap font (digits + colon) for AtomVM.

  A glyph is returned as `{width, height, rows}` where:
  - `rows` is a list of integers, one per row
  - bits are MSB-left within the glyph width (bit `width-1` is the leftmost pixel)
  - the caller decides scaling and foreground/background colors

  This keeps rendering logic out of the font module and makes it easy to reuse.
  """

  @w 5
  @h 7

  # Classic 5x7 digit set
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

  # Narrow 1-column colon (centered by spacing)
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

  # Fallback: blank box
  def glyph(_), do: {@w, @h, [0, 0, 0, 0, 0, 0, 0]}

  def height(), do: @h
end
