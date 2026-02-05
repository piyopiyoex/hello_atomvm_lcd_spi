defmodule SampleApp.SD do
  @moduledoc """
  SD card utilities for AtomVM.

  ## Path types

  AtomVM POSIX helpers and `:esp.mount/4` expect *charlists* for paths, not binaries.
  This module consistently uses charlists to avoid accidental type mismatches.

  ## Streaming philosophy

  Files are processed in chunks to avoid large allocations:
  - `stream_file_chunks/3` reads and yields binaries incrementally
  - `file_size/2` computes size via a read loop (simple and portable)

  ## Mount lifetime

  `mount/4` spawns a keepalive process that holds the mount reference reachable.
  This prevents the mount handle from being GC’d while the filesystem is in use.
  """

  @compile {:no_warn_undefined, :esp}
  @compile {:no_warn_undefined, :atomvm}

  @doc "Mount an SD card filesystem. Returns {:ok, mount_ref} or {:error, reason}."
  @spec mount(term(), non_neg_integer(), charlist(), charlist()) ::
          {:ok, term()} | {:error, term()}
  def mount(spi_host, cs_pin, root, driver \\ ~c"sdspi") do
    case :esp.mount(driver, root, :fat, spi_host: spi_host, cs: cs_pin) do
      {:ok, mount_ref} ->
        _keepalive_pid = spawn_link(fn -> keep_mount_alive(mount_ref) end)
        {:ok, mount_ref}

      {:error, reason} ->
        :io.format(~c"SD mount failed: ~p~n", [reason])
        {:error, reason}
    end
  end

  @doc "Print directory entries under `path`."
  @spec print_directory(charlist()) :: :ok | {:error, term()}
  def print_directory(path) do
    :io.format(~c"Listing ~s~n", [path])

    case with_dir(path, fn dir -> print_entries(dir) end) do
      :ok ->
        :ok

      {:error, reason} ->
        :io.format(~c"opendir(~s) failed: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  @doc "List `.RGB` files under `base` (sorted, full paths)."
  @spec list_rgb_files(charlist()) :: [charlist()]
  def list_rgb_files(base) do
    base
    |> list_entry_names()
    |> :lists.filter(&rgb_file_name?/1)
    |> :lists.map(&join_path(base, &1))
    |> :lists.sort()
  end

  @doc "Stream a file in `chunk_bytes` chunks. Returns {:ok, total_bytes} or {:error, reason}."
  @spec stream_file_chunks(charlist(), pos_integer(), (binary() -> any())) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_file_chunks(path, chunk_bytes, consumer_fun)
      when is_integer(chunk_bytes) and chunk_bytes > 0 and is_function(consumer_fun, 1) do
    with_open_readonly(path, fn fd ->
      stream_loop(fd, chunk_bytes, 0, consumer_fun)
    end)
  end

  @doc "Calculate file size by reading the file in chunks."
  @spec file_size(charlist(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(path, chunk_bytes) when is_integer(chunk_bytes) and chunk_bytes > 0 do
    with_open_readonly(path, fn fd ->
      {:ok, file_size_loop(fd, chunk_bytes, 0)}
    end)
  end

  defp join_path(base, rel) when is_list(base) and is_list(rel) do
    :filename.join(base, rel)
  end

  defp rgb_file_name?(name) when is_list(name) do
    :lists.suffix(~c".RGB", name) or :lists.suffix(~c".rgb", name)
  end

  # Keep the mount reference reachable for the lifetime of the system.
  # On embedded runtimes, "someone forgot to hold the ref" is a very real bug class.
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

  defp print_entries(dir) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name}} ->
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

  defp list_entry_names(base) do
    case with_dir(base, fn dir -> collect_entry_names(dir, []) end) do
      {:error, _} -> []
      names -> names
    end
  end

  defp collect_entry_names(dir, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name}} ->
        acc2 = if name == [], do: acc, else: [name | acc]
        collect_entry_names(dir, acc2)

      :eof ->
        :lists.reverse(acc)

      _ ->
        :lists.reverse(acc)
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
        :io.format(~c"open failed: ~p~n", [reason])
        {:error, reason}
    end
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
