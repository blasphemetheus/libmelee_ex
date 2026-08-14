defmodule Melee.SessionPoolTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Melee.{Session, SessionPool}

  # Same stub shape as Melee.SessionTest: no emulator, no Port.
  defmodule StubDolphin do
    @moduledoc false

    def launch(opts) do
      home = Keyword.fetch!(opts, :home)
      send(Keyword.fetch!(opts, :test_pid), {:launched, opts})

      {:ok,
       %Melee.Dolphin{
         port: nil,
         os_pid: nil,
         exe: "/stub/dolphin",
         home: home,
         slippi_port: Keyword.get(opts, :slippi_port, 51_441),
         flavor: :ishiiruka,
         temp_home?: false
       }}
    end

    def pipes_path(%Melee.Dolphin{home: home}, gc_port), do: Path.join(home, "pipe#{gc_port}")

    def stop(%Melee.Dolphin{home: home}) do
      File.touch!(Path.join(home, "STOPPED"))
      :ok
    end
  end

  defmodule LoopbackTransport do
    @moduledoc false
    @behaviour Melee.Transport

    @impl true
    def connect(_host, _port, owner, _opts) do
      conn = {:loopback, make_ref()}
      send(owner, {:enet_connected, conn})
      {:ok, conn}
    end

    @impl true
    def send(_conn, _channel, _data, :reliable), do: :ok

    @impl true
    def disconnect(_conn), do: :ok
  end

  setup ctx do
    home = Path.join(System.tmp_dir!(), "melee_pool_#{:erlang.phash2({ctx.test, self()})}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp session_opts(home) do
    [
      dolphin_module: StubDolphin,
      home: home,
      test_pid: self(),
      # No controllers: the stub has no fifos to open, and pool wiring is
      # what's under test, not the controller handshake.
      ports: [],
      console: [transport: LoopbackTransport, polling_mode: true, polling_timeout: 10]
    ]
  end

  test "starts N sessions with distinct ports and homes", %{home: home} do
    pool =
      start_supervised!({SessionPool, count: 3, session: session_opts(home), base_port: 55_000})

    sessions = SessionPool.sessions(pool)
    assert length(sessions) == 3
    assert Enum.map(sessions, &elem(&1, 0)) == [1, 2, 3]

    launches =
      for _ <- 1..3 do
        assert_received {:launched, opts}
        opts
      end

    ports = launches |> Enum.map(&Keyword.fetch!(&1, :slippi_port)) |> Enum.sort()
    homes = launches |> Enum.map(&Keyword.fetch!(&1, :home)) |> Enum.sort()

    assert length(Enum.uniq(ports)) == 3
    assert Enum.all?(ports, &(&1 >= 55_000))
    assert homes == Enum.map(1..3, &Path.join(home, "s#{&1}"))

    assert is_pid(SessionPool.session(pool, 2))
    assert SessionPool.session(pool, 9) == nil
  end

  test "a stopped session does not take down its siblings", %{home: home} do
    pool =
      start_supervised!({SessionPool, count: 2, session: session_opts(home), base_port: 55_100})

    [{1, s1}, {2, s2}] = SessionPool.sessions(pool)

    :ok = Session.stop(s1)
    refute Process.alive?(s1)
    assert Process.alive?(s2)

    # transient: the cleanly-stopped session stays down
    assert SessionPool.session(pool, 1) == nil
    assert SessionPool.session(pool, 2) == s2
  end

  test "refuses a shared slippi_port or name in the base opts", %{home: home} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: msg}, _}} =
             SessionPool.start_link(
               count: 1,
               session: Keyword.put(session_opts(home), :slippi_port, 51_441)
             )

    assert msg =~ ":slippi_port"

    assert {:error, {%ArgumentError{}, _}} =
             SessionPool.start_link(
               count: 1,
               session: Keyword.put(session_opts(home), :name, SomeName)
             )
  end
end
