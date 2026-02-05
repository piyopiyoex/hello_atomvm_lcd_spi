defmodule SampleApp.SPIBus do
  @moduledoc """
  Owns the SPI host handle and serializes all SPI bus activity.

  On this target we have multiple logical devices (LCD, touch, SD) on one physical bus.
  Interleaving operations like:
  - `LCD.set_window` → `LCD.begin_ram_write` → stream bytes
  with touch reads or SD block reads will corrupt transfers.

  `SPIBus` is a GenServer that acts as a bus-wide mutex:
  - `transaction/2` runs a function with the SPI host handle inside the server process
  - calls are serialized, so multi-step sequences remain atomic

  ## Guidance

  - Keep transactions short and focused.
  - Do not block inside a transaction longer than necessary.
  - Prefer one transaction per “SPI conversation” (set window + stream, one touch read burst, etc).
  """

  @compile {:no_warn_undefined, :spi}

  ## Public API

  def start_link(spi_config, opts \\ []) do
    :gen_server.start_link({:local, __MODULE__}, __MODULE__, spi_config, opts)
  end

  def spi_host(timeout \\ 5_000) do
    :gen_server.call(__MODULE__, :spi_host, timeout)
  end

  @doc """
  Run `fun.(spi_host)` while holding exclusive access to the SPI bus.

  Returns `{:ok, result}` or `{:error, reason}` if the function raised or threw.
  """
  def transaction(fun, timeout \\ :infinity) when is_function(fun, 1) do
    :gen_server.call(__MODULE__, {:transaction, fun}, timeout)
  end

  ## gen_server callbacks

  def init(spi_config) do
    spi = :spi.open(spi_config)
    {:ok, %{spi: spi}}
  end

  def handle_call(:spi_host, _from, state) do
    {:reply, state.spi, state}
  end

  def handle_call({:transaction, fun}, _from, %{spi: spi} = state) do
    reply =
      try do
        {:ok, fun.(spi)}
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    {:reply, reply, state}
  end

  def terminate(_reason, _state), do: :ok
end
