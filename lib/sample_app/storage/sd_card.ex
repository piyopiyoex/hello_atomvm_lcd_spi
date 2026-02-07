defmodule SampleApp.Storage.SDCard do
  @moduledoc """
  SD card helpers for AtomVM.

  - Paths are charlists (AtomVM POSIX expects flat charlists).
  - Reads are chunked to avoid big allocations.
  - Keeps the mount ref reachable to avoid GC-related unmount issues.
  """

  @compile {:no_warn_undefined, :esp}
  @compile {:no_warn_undefined, :atomvm}

  alias SampleApp.AtomVMCompat

  @spec mount(term(), non_neg_integer(), charlist() | binary(), charlist()) ::
          {:ok, term()} | {:error, term()}
  def mount(spi_host, cs_pin, root, driver \\ ~c"sdspi") do
    root = AtomVMCompat.ensure_charlist(root)

    case :esp.mount(driver, root, :fat, spi_host: spi_host, cs: cs_pin) do
      {:ok, mount_ref} ->
        _pid = spawn_link(fn -> keep_mount_alive(mount_ref) end)
        {:ok, mount_ref}

      {:error, reason} ->
        :io.format(~c"SDCard mount failed (root=~s): ~p~n", [root, reason])
        {:error, reason}
    end
  end

  @spec print_directory(charlist() | binary()) :: :ok | {:error, term()}
  def print_directory(path) do
    path = AtomVMCompat.ensure_charlist(path)
    :io.format(~c"Listing ~s~n", [path])

    case with_dir(path, fn dir -> print_entries(dir) end) do
      :ok ->
        :ok

      {:error, reason} ->
        :io.format(~c"opendir(~s) failed: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  @doc """
  Return the first `.rgb`/`.RGB` file found under `base`, or `:none`.
  This is intentionally memory-light (no full list, no sort).
  """
  @spec first_rgb_file(charlist() | binary()) :: {:ok, charlist()} | :none | {:error, term()}
  def first_rgb_file(base) do
    base = AtomVMCompat.ensure_charlist(base)
    with_dir(base, fn dir -> find_first_rgb(dir, base) end)
  end

  @doc """
  List `.rgb`/`.RGB` files under `base` (full paths).
  """
  @spec list_rgb_files(charlist() | binary()) :: [charlist()]
  def list_rgb_files(base) do
    base = AtomVMCompat.ensure_charlist(base)

    case with_dir(base, fn dir -> collect_rgb_files(dir, base, []) end) do
      {:error, _} -> []
      files when is_list(files) -> files
      _ -> []
    end
  end

  @spec stream_file_chunks(charlist() | binary(), pos_integer(), (binary() -> any())) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_file_chunks(path, chunk_bytes, consumer_fun)
      when is_integer(chunk_bytes) and chunk_bytes > 0 and is_function(consumer_fun, 1) do
    path = AtomVMCompat.ensure_charlist(path)

    with_open_readonly(path, fn fd ->
      stream_loop(fd, chunk_bytes, 0, consumer_fun)
    end)
  end

  @spec file_size(charlist() | binary(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def file_size(path, chunk_bytes) when is_integer(chunk_bytes) and chunk_bytes > 0 do
    path = AtomVMCompat.ensure_charlist(path)

    with_open_readonly(path, fn fd ->
      {:ok, file_size_loop(fd, chunk_bytes, 0)}
    end)
  end

  ## Internals

  defp keep_mount_alive(mount_ref) do
    _ = mount_ref
    Process.sleep(:infinity)
  end

  defp with_dir(path, fun) when is_function(fun, 1) do
    case :atomvm.posix_opendir(path) do
      {:ok, dir} ->
        try do
          fun.(dir)
        after
          :atomvm.posix_closedir(dir)
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp with_open_readonly(path, fun) when is_function(fun, 1) do
    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        try do
          fun.(fd)
        after
          :atomvm.posix_close(fd)
        end

      {:error, reason} ->
        :io.format(~c"open(~s) failed: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  defp print_entries(dir) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name0}} ->
        name = AtomVMCompat.normalize_name(name0)
        if name != [], do: :io.format(~c"  - ~s~n", [name])
        print_entries(dir)

      :eof ->
        :ok

      {:error, reason} ->
        :io.format(~c"readdir error: ~p~n", [reason])
        :ok

      _ ->
        :ok
    end
  end

  defp find_first_rgb(dir, base) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name0}} ->
        name = AtomVMCompat.normalize_name(name0)

        if rgb_file_name?(name) do
          {:ok, AtomVMCompat.join_path(base, name)}
        else
          find_first_rgb(dir, base)
        end

      :eof ->
        :none

      {:error, reason} ->
        {:error, reason}

      _ ->
        :none
    end
  end

  defp collect_rgb_files(dir, base, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name0}} ->
        name = AtomVMCompat.normalize_name(name0)

        acc2 =
          if rgb_file_name?(name) do
            [AtomVMCompat.join_path(base, name) | acc]
          else
            acc
          end

        collect_rgb_files(dir, base, acc2)

      :eof ->
        :lists.reverse(acc)

      _ ->
        :lists.reverse(acc)
    end
  end

  defp rgb_file_name?(name0) do
    name = AtomVMCompat.normalize_name(name0)

    AtomVMCompat.ends_with_charlist?(name, ~c".RGB") or
      AtomVMCompat.ends_with_charlist?(name, ~c".rgb")
  end

  defp stream_loop(fd, chunk_bytes, total, consumer_fun) do
    case :atomvm.posix_read(fd, chunk_bytes) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        _ = consumer_fun.(bin)
        stream_loop(fd, chunk_bytes, total + byte_size(bin), consumer_fun)

      :eof ->
        {:ok, total}

      {:error, reason} ->
        :io.format(~c"read error: ~p~n", [reason])
        {:error, reason}

      _ ->
        {:ok, total}
    end
  end

  defp file_size_loop(fd, chunk_bytes, total) do
    case :atomvm.posix_read(fd, chunk_bytes) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        file_size_loop(fd, chunk_bytes, total + byte_size(bin))

      :eof ->
        total

      _ ->
        total
    end
  end
end
