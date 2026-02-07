defmodule SampleApp.Drivers.Touch do
  @moduledoc """
  Resistive touch reader for XPT2046/ADS7846-style controllers.

  Responsibilities (driver-only):
  - Polls over SPI and reads raw ADC values (X/Y/Z).
  - Applies calibration + rotation to map raw values into screen coordinates.
  - Optionally applies EMA smoothing.
  - Optionally sends events to a `:notify` process:
    - `{:touch, x, y, z}`
    - `{:touch_up, x, y}` (emitted when a previously-active touch is released)

  Touch and Display share one SPI bus, so reads must run inside `SPI.transaction/2`.
  """

  @compile {:no_warn_undefined, :spi}
  @compile {:no_warn_undefined, :gpio}

  import Bitwise

  alias SampleApp.Buses.SPI

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

  # Default calibration window
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

  # EMA smoothing (0..1). 1.0 = no smoothing.
  @default_ema_alpha 1.0

  # Some controllers benefit from discarding the first conversion after a channel switch.
  @discard_first_conversion true

  ## Public API

  def start_link(opts \\ []) do
    :gen_server.start_link(__MODULE__, opts, [])
  end

  def stop(pid), do: :gen_server.stop(pid)

  @doc """
  Capture raw touch ADC extremes for calibration.

  Samples the touch controller for `duration_ms` milliseconds while you press/drag
  near the four corners/edges. Returns the observed raw min/max values:

  `%{xmin: .., xmax: .., ymin: .., ymax: ..}`

  Use these as `raw_x_min/raw_x_max/raw_y_min/raw_y_max` in the calibration config.
  """
  def capture_extremes(duration_ms \\ 3000) do
    case SPI.transaction(&capture_extremes_on_spi(&1, duration_ms), :infinity) do
      {:ok, ex} -> ex
      _ -> %{}
    end
  end

  ## gen_server callbacks

  def init(opts) do
    notify = notify_pid(opts)

    setup_irq()

    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    rotation = Keyword.get(opts, :rotation, @default_rotation)
    ema_alpha = Keyword.get(opts, :ema_alpha, @default_ema_alpha)

    cal = calibration(opts)
    {screen_w, screen_h, native_w, native_h} = dimensions(rotation)

    state = %{
      notify: notify,
      poll_ms: poll_ms,
      rotation: rotation,
      ema_alpha: ema_alpha,
      screen_w: screen_w,
      screen_h: screen_h,
      native_w: native_w,
      native_h: native_h,
      cal: cal,
      last_xy: nil,
      last_ts: nil,
      filt_xy: nil
    }

    log_ready(state)
    schedule_poll(poll_ms)

    {:ok, state}
  end

  def handle_info(:poll, state) do
    {state2, event} =
      case SPI.transaction(&poll_on_spi(&1, state), :infinity) do
        {:ok, {st, ev}} -> {st, ev}
        _ -> {state, nil}
      end

    if event != nil and state2.notify != nil, do: send(state2.notify, event)

    schedule_poll(state2.poll_ms)
    {:noreply, state2}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp notify_pid(opts) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp setup_irq do
    case @pin_irq do
      nil -> :ok
      pin -> :gpio.set_pin_mode(pin, :input)
    end
  end

  defp calibration(opts) do
    cal = Keyword.get(opts, :calibration, [])

    %{
      raw_x_min: Keyword.get(cal, :raw_x_min, @default_raw_x_min),
      raw_x_max: Keyword.get(cal, :raw_x_max, @default_raw_x_max),
      raw_y_min: Keyword.get(cal, :raw_y_min, @default_raw_y_min),
      raw_y_max: Keyword.get(cal, :raw_y_max, @default_raw_y_max),
      swap_xy: Keyword.get(cal, :swap_xy, @default_swap_xy),
      invert_x: Keyword.get(cal, :invert_x, @default_invert_x),
      invert_y: Keyword.get(cal, :invert_y, @default_invert_y)
    }
  end

  defp dimensions(rotation) do
    screen_w = SampleApp.Drivers.Display.width()
    screen_h = SampleApp.Drivers.Display.height()

    {native_w, native_h} =
      if rotation in [1, 3], do: {screen_h, screen_w}, else: {screen_w, screen_h}

    {screen_w, screen_h, native_w, native_h}
  end

  defp log_ready(state) do
    :io.format(~c"[touch] ready (poll=~pms rot=~p ema=~p)~n", [
      state.poll_ms,
      state.rotation,
      state.ema_alpha
    ])
  end

  defp schedule_poll(poll_ms) do
    Process.send_after(self(), :poll, poll_ms)
  end

  defp poll_on_spi(spi, state) do
    if pressed?() do
      poll_pressed(spi, state)
    else
      poll_released(spi, state)
    end
  end

  defp pressed? do
    case @pin_irq do
      nil -> true
      pin -> :gpio.digital_read(pin) == :low
    end
  end

  defp poll_pressed(spi, state) do
    case read_touch(spi) do
      {:ok, {raw_x, raw_y, z}} ->
        handle_touch_sample(state, raw_x, raw_y, z)

      :none ->
        maybe_emit_touch_up(state)

      {:error, _} ->
        {state, nil}
    end
  end

  defp poll_released(_spi, state) do
    maybe_emit_touch_up(state)
  end

  defp maybe_emit_touch_up(%{last_xy: nil} = state) do
    {%{state | filt_xy: nil}, nil}
  end

  defp maybe_emit_touch_up(%{last_xy: {_x, _y}, notify: nil} = state) do
    {%{state | last_xy: nil, last_ts: nil, filt_xy: nil}, nil}
  end

  defp maybe_emit_touch_up(%{last_xy: {x, y}} = state) do
    {%{state | last_xy: nil, last_ts: nil, filt_xy: nil}, {:touch_up, x, y}}
  end

  defp handle_touch_sample(state, raw_x, raw_y, z) do
    {x0, y0} = to_screen_point(raw_x, raw_y, state)
    {xf, yf} = ema_filter({x0, y0}, state.filt_xy, state.ema_alpha)

    xi = trunc(xf + 0.5)
    yi = trunc(yf + 0.5)

    {new_last_ts, maybe_event} =
      maybe_event(state.notify, {xi, yi, z}, state.last_ts, state.last_xy)

    state2 = %{
      state
      | last_xy: {xi, yi},
        last_ts: new_last_ts,
        filt_xy: {xf, yf}
    }

    {state2, maybe_event}
  end

  defp ema_filter({x, y}, {px, py}, a) when is_number(a) and is_number(px) and is_number(py) do
    {px + a * (x - px), py + a * (y - py)}
  end

  defp ema_filter({x, y}, _prev, _a), do: {x * 1.0, y * 1.0}

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

  # XPT2046 returns a 12-bit value left-aligned in the 16-bit payload.
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

  ## Raw -> screen mapping

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
end
