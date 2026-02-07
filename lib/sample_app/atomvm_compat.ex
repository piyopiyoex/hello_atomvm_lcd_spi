defmodule SampleApp.AtomVMCompat do
  @moduledoc """
  AtomVM compatibility helpers.
  """

  @doc """
  Ensure `value` is a flat charlist suitable for AtomVM POSIX calls.
  """
  @spec ensure_charlist(charlist() | binary()) :: charlist()
  def ensure_charlist(value) when is_binary(value), do: :erlang.binary_to_list(value)

  def ensure_charlist(value) when is_list(value) do
    if flat_charlist?(value) do
      value
    else
      raise ArgumentError, "expected a flat charlist, got: #{inspect(value)}"
    end
  end

  def ensure_charlist(value) do
    raise ArgumentError, "expected charlist/binary, got: #{inspect(value)}"
  end

  @doc """
  Normalize a dirent name returned by AtomVM POSIX APIs.
  """
  @spec normalize_name(term()) :: charlist()
  def normalize_name(name) when is_list(name) do
    if flat_charlist?(name) do
      name
    else
      raise ArgumentError, "expected a flat charlist name, got: #{inspect(name)}"
    end
  end

  def normalize_name(name) when is_binary(name), do: :erlang.binary_to_list(name)
  def normalize_name(_), do: []

  @doc """
  Join two path segments as a flat charlist.
  """
  @spec join_path(charlist() | binary(), charlist() | binary()) :: charlist()
  def join_path(base, rel) do
    # Intentionally explicit to avoid producing surprising list shapes.
    base = ensure_charlist(base)
    rel = normalize_name(rel)
    base ++ ~c"/" ++ rel
  end

  @doc """
  Heap-friendly suffix check for flat charlists.
  """
  @spec ends_with_charlist?(charlist(), charlist()) :: boolean()
  def ends_with_charlist?(list, suffix) when is_list(list) and is_list(suffix) do
    # Uses `length/1` + `:lists.nthtail/2` to avoid allocating a reversed copy.
    l1 = length(list)
    l2 = length(suffix)
    l1 >= l2 and :lists.nthtail(l1 - l2, list) == suffix
  end

  defp flat_charlist?([]), do: true
  defp flat_charlist?([h | t]) when is_integer(h) and h >= 0 and h <= 255, do: flat_charlist?(t)
  defp flat_charlist?(_), do: false
end
