defmodule Melee.SessionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Melee.Session

  # --- stubs ---------------------------------------------------------------

  # Stands in for `Melee.Dolphin`: no emulator, no Port. `launch/1`
  # reports to the test process; `stop/1` leaves a marker file in the
  # home (the struct carries nowhere to stash a pid, and marker files
  # keep the test async-safe).
  defmodule StubDolphin do
    @moduledoc false

    def launch(opts) do
      home = Keyword.fetch!(opts, :home)
      send(Keyword.fetch!(opts, :test_pid), {:step, :dolphin_launch, opts})

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

  # A transport that completes the ENet handshake immediately, so a
  # console can be driven without a real Dolphin.
  defmodule LoopbackTransport do
    @moduledoc false
    @behaviour Melee.Transport

    @impl true
    def connect(_host, _port, owner, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:step, :console_connect})
      conn = {:loopback, make_ref()}
      send(owner, {:enet_connected, conn})
      {:ok, conn}
    end

    @impl true
    def send(_conn, _channel, _data, :reliable), do: :ok

    @impl true
    def disconnect(_conn), do: :ok
  end

  # A transport whose connect always fails, to exercise the retry budget.
  defmodule DeadTransport do
    @moduledoc false
    @behaviour Melee.Transport

    @impl true
    def connect(_host, _port, _owner, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:step, :console_connect})
      {:error, :econnrefused}
    end

    @impl true
    def send(_conn, _channel, _data, :reliable), do: :ok

    @impl true
    def disconnect(_conn), do: :ok
  end

  # --- harness -------------------------------------------------------------

  setup ctx do
    home = Path.join(System.tmp_dir!(), "melee_session_#{:erlang.phash2({ctx.test, self()})}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp opts(home, extra \\ []) do
    Keyword.merge(
      [
        dolphin_module: StubDolphin,
        home: home,
        test_pid: self(),
        ports: [1],
        console: [
          transport: LoopbackTransport,
          transport_opts: [test_pid: self()],
          polling_mode: true,
          polling_timeout: 10
        ]
      ],
      extra
    )
  end

  defp start_session(home, extra \\ []) do
    {:ok, session} = Session.start_link(opts(home, extra))
    on_exit(fn -> Session.stop(session) end)
    session
  end

  # --- tests ---------------------------------------------------------------

  describe "child_spec/1" do
    test "is a transient worker named after :name" do
      opts = [name: MyApp.Session, path: "/x", iso_path: "/y"]

      assert Session.child_spec(opts) == %{
               id: MyApp.Session,
               start: {Session, :start_link, [opts]},
               type: :worker,
               restart: :transient,
               shutdown: 15_000
             }
    end

    test "falls back to the module as the child id" do
      assert %{id: Melee.Session} = Session.child_spec([])
    end
  end

  describe "start_link/1" do
    test "launches Dolphin, connects the console, then opens controllers", %{home: home} do
      session = start_session(home)

      assert_receive {:step, :dolphin_launch, launch_opts}
      assert_receive {:step, :console_connect}

      # :ports becomes Dolphin's :controller_ports so pad config is
      # written before the process boots.
      assert launch_opts[:controller_ports] == [1]
      # Session-only options are not forwarded to the launcher.
      refute Keyword.has_key?(launch_opts, :console)
      refute Keyword.has_key?(launch_opts, :ports)

      controller = Session.controller(session, 1)
      assert is_pid(controller)
      assert Process.alive?(controller)
      assert Session.controller(session, 2) == nil

      assert is_pid(Session.console(session))
      assert %Melee.Dolphin{home: ^home} = Session.dolphin(session)
    end

    test "the controller fifo is opened only after Dolphin and the console", %{home: home} do
      # A real fifo blocks on open until the reader shows up, which is
      # what makes the ordering observable.
      fifo = Path.join(home, "pipe1")
      {_, 0} = System.cmd("mkfifo", [fifo])

      test_pid = self()
      opts = opts(home)
      starter = Task.async(fn -> send(test_pid, {:started, Session.start_link(opts)}) end)

      assert_receive {:step, :dolphin_launch, _}, 2_000
      assert_receive {:step, :console_connect}, 2_000
      # Still blocked on the fifo: startup has not returned.
      refute_receive {:started, _}, 200

      reader = Task.async(fn -> File.open!(fifo, [:read, :raw]) end)

      assert_receive {:started, {:ok, session}}, 5_000
      on_exit(fn -> Session.stop(session) end)
      Task.await(reader, 5_000)
      Task.await(starter, 5_000)
    end

    test "creates one controller per :port", %{home: home} do
      session = start_session(home, ports: [1, 3])

      assert is_pid(Session.controller(session, 1))
      assert is_pid(Session.controller(session, 3))
      assert Session.controller(session, 2) == nil
    end

    test "a console that never connects aborts the session and stops Dolphin", %{home: home} do
      Process.flag(:trap_exit, true)

      opts =
        opts(home,
          console: [transport: DeadTransport, transport_opts: [test_pid: self()]],
          connect_attempts: 2,
          connect_backoff_ms: 1
        )

      assert {:error, {:console_connect_failed, :econnrefused}} = Session.start_link(opts)

      assert_receive {:step, :console_connect}
      assert_receive {:step, :console_connect}
      # Dolphin must not be left running behind a half-built session.
      assert File.exists?(Path.join(home, "STOPPED"))
    end
  end

  describe "step/2" do
    test "delegates to the console", %{home: home} do
      session = start_session(home)
      # Polling console with no frames: nil, same as Console.step/2.
      assert Session.step(session, 5_000) == nil
    end
  end

  describe "controller restart" do
    test "a crashed controller is restarted and re-registered", %{home: home} do
      session = start_session(home)
      console = Session.console(session)
      original = Session.controller(session, 1)

      ref = Process.monitor(original)
      Process.exit(original, :kill)
      assert_receive {:DOWN, ^ref, :process, ^original, :killed}

      restarted = wait_for_new_controller(session, original)
      assert Process.alive?(restarted)
      assert Process.alive?(console)
      assert Process.alive?(session)

      # Re-registered: a step flushes it to the (freshly truncated) pipe.
      assert Session.step(session, 5_000) == nil
      assert File.read!(Path.join(home, "pipe1")) =~ "FLUSH\n"
    end

    test "the console survives a controller that dies mid-flight", %{home: home} do
      session = start_session(home)
      console = Session.console(session)
      controller = Session.controller(session, 1)

      Process.exit(controller, :kill)
      assert Session.step(session, 5_000) == nil
      assert Process.alive?(console)
    end
  end

  describe "stop/1" do
    test "tears down controllers, console and Dolphin, and is idempotent", %{home: home} do
      {:ok, session} = Session.start_link(opts(home))
      console = Session.console(session)
      controller = Session.controller(session, 1)

      assert :ok = Session.stop(session)

      refute Process.alive?(session)
      refute Process.alive?(console)
      refute Process.alive?(controller)
      assert File.exists?(Path.join(home, "STOPPED"))

      # Stopping a dead session is a no-op, not an exit.
      assert :ok = Session.stop(session)
    end
  end

  defp wait_for_new_controller(session, original, tries \\ 100) do
    case Session.controller(session, 1) do
      ^original when tries > 0 ->
        Process.sleep(10)
        wait_for_new_controller(session, original, tries - 1)

      pid when is_pid(pid) and pid != original ->
        pid
    end
  end
end
