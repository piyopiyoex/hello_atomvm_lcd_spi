defmodule SampleApp.UI.TouchOverlay.OSD do
  @moduledoc false

  @enforce_keys [:x0, :y0, :cell_w, :cell_h, :total_w, :total_h, :glyphs]
  defstruct [
    :x0,
    :y0,
    :cell_w,
    :cell_h,
    :total_w,
    :total_h,
    :glyphs,
    last_chars: nil,
    drawn?: false
  ]

  @type t :: %__MODULE__{
          x0: non_neg_integer(),
          y0: non_neg_integer(),
          cell_w: pos_integer(),
          cell_h: pos_integer(),
          total_w: pos_integer(),
          total_h: pos_integer(),
          glyphs: map(),
          last_chars: binary() | nil,
          drawn?: boolean()
        }
end
