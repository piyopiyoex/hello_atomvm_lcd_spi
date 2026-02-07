defmodule SampleApp.Buses.SPI do
  @moduledoc """
  Owns the SPI host handle and serializes all SPI bus activity.

  On this target we have multiple logical devices (Display, touch, SDCard) on one physical bus.
  Interleaving operations like:
  - `Display.set_window` → `Display.begin_ram_write` → stream bytes
  with touch reads or SDCard block reads will corrupt transfers.

  `SPI` is a GenServer that acts as a bus-wide mutex:
  - `transaction/2` runs a function with the SPI host handle inside the server process
  - calls are serialized, so multi-step sequences remain atomic
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
  """
  @spec transaction((term() -> term()), non_neg_integer() | :infinity) ::
          {:ok, term()} | {:error, term()}
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

  def terminate(_reason, %{spi: spi}) do
    :spi.close(spi)
    :ok
  end
end
