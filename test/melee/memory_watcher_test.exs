defmodule Melee.MemoryWatcherTest do
  use ExUnit.Case, async: true

  alias Melee.MemoryWatcher

  describe "render_locations/1 + normalize_watches/1" do
    test "keyword watches render one line each, trailing newline" do
      assert MemoryWatcher.render_locations(rng: "804D5F90", scene: "80479D30") ==
               "804D5F90\n80479D30\n"
    end

    test "bare strings double as names" do
      assert MemoryWatcher.normalize_watches(["804D5F90"]) == [{"804D5F90", "804D5F90"}]
    end

    test "pointer chains keep offsets space-separated; whitespace collapses" do
      # Dolphin round-trips the line VERBATIM as the datagram key, so
      # normalization must be deterministic before the file is written.
      assert MemoryWatcher.normalize_watches(p1: "  80453080   2C  70 ") ==
               [p1: "80453080 2C 70"]
    end
  end

  describe "parse_datagram/1" do
    # THE FORMAT (mainline-slippi dolphin, ComposeMessages, read
    # verbatim from source 2026-08-22): per changed entry
    # "line\nhexvalue\n", batched into ONE datagram per step, plus a
    # trailing NUL from `sendto(..., message.size() + 1, ...)`. An
    # unchanged step sends a bare "\0". The original parser expected
    # Ishiiruka's "line\nhexvalue\0" (NO trailing newline) and silently
    # rejected every real mainline message — the 08-22 field bug.
    test "MAINLINE single-entry frame: trailing newline before NUL" do
      assert MemoryWatcher.parse_datagram("804D5F90\naf83bc16\n\0") ==
               {:ok, [{"804D5F90", 0xAF83BC16}]}
    end

    test "MAINLINE composite frame: multiple entries in one datagram" do
      assert MemoryWatcher.parse_datagram("804D5F90\n1\n80479D30\n6\n\0") ==
               {:ok, [{"804D5F90", 1}, {"80479D30", 6}]}
    end

    test "classic Ishiiruka frame (no trailing newline) still parses" do
      assert MemoryWatcher.parse_datagram("804D5F90\naf83bc16\0") ==
               {:ok, [{"804D5F90", 0xAF83BC16}]}
    end

    test "pointer-chain keys parse" do
      assert MemoryWatcher.parse_datagram("80453080 2C 70\n1\n\0") ==
               {:ok, [{"80453080 2C 70", 1}]}
    end

    test "empty-step and junk frames drop: bare NUL, empty, bad hex, odd parts" do
      assert MemoryWatcher.parse_datagram("\0") == :error
      assert MemoryWatcher.parse_datagram("") == :error
      assert MemoryWatcher.parse_datagram("804D5F90\nzz\n\0") == :error
      assert MemoryWatcher.parse_datagram("only-one-part\0") == :error
      assert MemoryWatcher.parse_datagram("a\n1\nodd\n\0") == :error
    end
  end

  # ---------------------------------------------------------------
  # HtDP-style data definition for a dolphin->watcher datagram:
  #
  #   Datagram = EmptyStep | Composite
  #   EmptyStep = <<0>>                         ; unchanged step
  #   Composite = (Entry)+ <<0>>                ; >=1 changed entries
  #   Entry     = Line "\n" HexValue "\n"
  #   Line      = HexToken (" " HexToken)*      ; verbatim Locations line
  #   HexValue  = lowercase hex, no prefix, 1..8 digits (u32)
  #
  # Input classes for parse_datagram: empty step / single entry /
  # multi entry / classic (Ishiiruka, entry missing final "\n") /
  # malformed (bad hex, odd part count, empty). Value boundaries:
  # 0, 1, 0xFFFFFFFF. The tests below enumerate each class.
  # ---------------------------------------------------------------
  describe "parse_datagram/1 — systematic input classes" do
    test "value boundaries: zero, max u32" do
      assert MemoryWatcher.parse_datagram("A\n0\n\0") == {:ok, [{"A", 0}]}
      assert MemoryWatcher.parse_datagram("A\nffffffff\n\0") == {:ok, [{"A", 0xFFFFFFFF}]}
      assert MemoryWatcher.parse_datagram("A\nFFFFFFFF\n\0") == {:ok, [{"A", 0xFFFFFFFF}]}
    end

    test "full 27-entry composite (the whole menu_with_canary set in one step)" do
      entries = Enum.map(1..27, fn i -> {"80#{Integer.to_string(0x400000 + i, 16)}", i} end)
      frame = Enum.map_join(entries, "", fn {l, v} -> "#{l}\n#{Integer.to_string(v, 16)}\n" end) <> "\0"
      assert MemoryWatcher.parse_datagram(frame) == {:ok, entries}
    end

    test "composite mixing known and unknown lines parses whole" do
      assert MemoryWatcher.parse_datagram("KNOWN\n1\nUNKNOWN\n2\n\0") ==
               {:ok, [{"KNOWN", 1}, {"UNKNOWN", 2}]}
    end

    test "totality property: parse_datagram never raises on arbitrary bytes" do
      # The receive path feeds parse_datagram RAW socket data; a crash
      # there kills the watcher mid-session. Junk must return :error,
      # never raise — including non-UTF8 bytes and embedded NULs.
      for _ <- 1..200 do
        len = :rand.uniform(64)
        data = :crypto.strong_rand_bytes(len)

        case MemoryWatcher.parse_datagram(data) do
          {:ok, updates} when is_list(updates) -> :ok
          :error -> :ok
        end
      end

      # Adversarial shapes seen or imaginable on the wire.
      for data <- [
            <<0, 0, 0>>,
            "\n\n\n\0",
            "804D5F90\n\n\0",
            "\n804D5F90\n1\n\0",
            <<255, 254, 10, 49, 10, 0>>,
            String.duplicate("a\n1\n", 500) <> <<0>>
          ] do
        case MemoryWatcher.parse_datagram(data) do
          {:ok, updates} when is_list(updates) -> :ok
          :error -> :ok
        end
      end
    end

    test "roundtrip property: any rendered watch set's keys parse back verbatim" do
      # 30 random watch sets; the compose side is simulated from the
      # rendered Locations lines (dolphin echoes lines verbatim).
      for _ <- 1..30 do
        n = :rand.uniform(6)

        watches =
          for i <- 1..n do
            chain =
              Enum.map_join(1..:rand.uniform(3), " ", fn _ ->
                Integer.to_string(:rand.uniform(0xFFFFFF), 16)
              end)

            {:"w#{i}", chain}
          end

        normalized = MemoryWatcher.normalize_watches(watches)
        frame = Enum.map_join(normalized, "", fn {_, l} -> "#{l}\n1\n" end) <> "\0"
        {:ok, updates} = MemoryWatcher.parse_datagram(frame)
        assert Enum.map(updates, &elem(&1, 0)) == Enum.map(normalized, &elem(&1, 1))
      end
    end
  end

  describe "get_f32/2 — bit reinterpretation classes" do
    # Observed live: a stale CSS address decoding to a DENORMAL
    # (4.77e-39) — the decode must be total over all u32 bit patterns.
    setup do
      home = Path.join(System.tmp_dir!(), "mw_f32_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    test "zero, negative zero, denormal, ordinary float, NaN bits", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [x: "80000000"])
      path = Path.join(home, "MemoryWatcher/MemoryWatcher")
      {:ok, s} = :socket.open(:local, :dgram, :default)

      send_u32 = fn u32 ->
        :ok = :socket.sendto(s, "80000000\n#{Integer.to_string(u32, 16)}\n\0", %{family: :local, path: path})
        Process.sleep(50)
      end

      send_u32.(0x00000000)
      assert MemoryWatcher.get_f32(w, :x) == {:ok, 0.0}

      send_u32.(0x80000000)
      assert MemoryWatcher.get_f32(w, :x) == {:ok, -0.0}

      # -23.0433... the live CSS cursor x (0xC1B858C6-ish class)
      send_u32.(0xC1B858C6)
      {:ok, v} = MemoryWatcher.get_f32(w, :x)
      assert_in_delta v, -23.04, 0.01

      # denormal (the live stale-address read)
      send_u32.(0x00340000)
      {:ok, d} = MemoryWatcher.get_f32(w, :x)
      assert d > 0 and d < 1.0e-37

      # NaN bits must not crash the decode path
      send_u32.(0x7FC00000)
      case MemoryWatcher.get_f32(w, :x) do
        {:ok, f} -> assert f == :nan
        other -> flunk("NaN bits crashed decode: #{inspect(other)}")
      end
    end
  end

  describe "subscription semantics" do
    setup do
      home = Path.join(System.tmp_dir!(), "mw_sub_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    defp push(home, line, hex) do
      {:ok, s} = :socket.open(:local, :dgram, :default)

      :ok =
        :socket.sendto(s, "#{line}\n#{hex}\n\0", %{
          family: :local,
          path: Path.join(home, "MemoryWatcher/MemoryWatcher")
        })

      :socket.close(s)
    end

    test ":all subscriber sees every watch; named sees only its own", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [a: "AA", b: "BB"])
      :ok = MemoryWatcher.subscribe(w, :a)
      push(home, "AA", "1")
      push(home, "BB", "2")
      assert_receive {:memory_watch, :a, 1}, 1_000
      refute_receive {:memory_watch, :b, _}, 200
    end

    test "a subscriber subscribed as both :all and named gets both messages (documented double-notify)",
         %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      :ok = MemoryWatcher.subscribe(w, :a)
      :ok = MemoryWatcher.subscribe(w, :all)
      push(home, "AA", "5")
      assert_receive {:memory_watch, :a, 5}, 1_000
      assert_receive {:memory_watch, :a, 5}, 1_000
    end

    test "dead subscribers are pruned, watcher survives", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])

      pid =
        spawn(fn ->
          MemoryWatcher.subscribe(w, :a)

          receive do
            :never -> :ok
          end
        end)

      Process.sleep(50)
      Process.exit(pid, :kill)
      Process.sleep(50)
      push(home, "AA", "7")
      Process.sleep(100)
      assert MemoryWatcher.get(w, :a) == {:ok, 7}
      assert Process.alive?(w)
    end

    test "unknown-line updates are stored under the raw line, not dropped", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      push(home, "STALE_LINE", "9")
      Process.sleep(100)
      assert MemoryWatcher.get(w, "STALE_LINE") == {:ok, 9}
    end
  end

  describe "traffic/1 — the liveness ratchet" do
    # Data definition: a MONOTONE count of datagrams received,
    # parse-independent. Frame classes that must count: parseable
    # change frames, bare-NUL empty steps (sent EVERY step — the
    # signal that makes liveness work with zero value changes), junk.
    setup do
      home = Path.join(System.tmp_dir!(), "mw_traffic_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    defp push_raw(home, data) do
      {:ok, s} = :socket.open(:local, :dgram, :default)

      :ok =
        :socket.sendto(s, data, %{
          family: :local,
          path: Path.join(home, "MemoryWatcher/MemoryWatcher")
        })

      :socket.close(s)
    end

    test "starts at zero; every frame class counts; count is monotone", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      assert MemoryWatcher.traffic(w) == 0

      # change frame + empty step + junk = 3
      push_raw(home, "AA\n1\n\0")
      push_raw(home, "\0")
      push_raw(home, <<255, 254, 0>>)
      Process.sleep(100)
      assert MemoryWatcher.traffic(w) == 3

      # A quiet interval holds the count (delta == 0 = "not advancing").
      Process.sleep(50)
      assert MemoryWatcher.traffic(w) == 3

      push_raw(home, "\0")
      Process.sleep(100)
      assert MemoryWatcher.traffic(w) == 4
      MemoryWatcher.stop(w)
    end
  end

  describe "lifecycle edges" do
    setup do
      home = Path.join(System.tmp_dir!(), "mw_life_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    test "restart on the same home rebinds over the stale socket file", %{home: home} do
      {:ok, w1} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      MemoryWatcher.stop(w1)
      # Stale socket FILE remains; a fresh watcher must File.rm + rebind.
      {:ok, w2} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      push(home, "AA", "3")
      Process.sleep(100)
      assert MemoryWatcher.get(w2, :a) == {:ok, 3}
      MemoryWatcher.stop(w2)
    end

    test "Locations.txt is rewritten on restart with the new watch set", %{home: home} do
      {:ok, w1} = MemoryWatcher.start_link(home: home, watches: [a: "AA"])
      MemoryWatcher.stop(w1)
      {:ok, w2} = MemoryWatcher.start_link(home: home, watches: [b: "BB", c: "CC"])
      assert File.read!(Path.join(home, "MemoryWatcher/Locations.txt")) == "BB\nCC\n"
      MemoryWatcher.stop(w2)
    end
  end

  describe "watcher lifecycle (socket, no dolphin)" do
    setup do
      home = Path.join(System.tmp_dir!(), "mw_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    test "writes Locations.txt and binds the socket; values flow end-to-end", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [rng: "804D5F90"])

      assert File.read!(Path.join(home, "MemoryWatcher/Locations.txt")) == "804D5F90\n"
      assert MemoryWatcher.get(w, :rng) == :unknown

      # Impersonate dolphin: sendto the bound socket.
      :ok = MemoryWatcher.subscribe(w, :rng)
      {:ok, s} = :socket.open(:local, :dgram, :default)

      :ok =
        :socket.sendto(s, "804D5F90\ndeadbeef\0", %{
          family: :local,
          path: Path.join(home, "MemoryWatcher/MemoryWatcher")
        })

      assert_receive {:memory_watch, :rng, 0xDEADBEEF}, 1_000
      assert MemoryWatcher.get(w, :rng) == {:ok, 0xDEADBEEF}

      # f32 reinterpretation of the same 4 bytes (big-endian).
      <<expected::float-big-32>> = <<0xDEADBEEF::32>>
      assert MemoryWatcher.get_f32(w, :rng) == {:ok, expected}

      :socket.close(s)
      MemoryWatcher.stop(w)
    end

    test "raises on empty watches", %{home: home} do
      Process.flag(:trap_exit, true)
      assert {:error, _} = MemoryWatcher.start_link(home: home, watches: [])
    end
  end

  describe "dolphin-pattern stream (2026-08-22 field failure repro)" do
    # Field observation: dolphin's stream (18-byte change messages
    # interleaved with 1-byte NUL empty-composites at ~60/s) arrived at
    # the module as ONLY the NUL frames. These tests pin the expected
    # behavior of the receive path under exactly that pattern, from an
    # EXTERNAL OS process (dolphin's position).
    setup do
      home = Path.join(System.tmp_dir!(), "mw_stream_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home}
    end

    defp external_stream(path, frames_script) do
      # Sends from a separate beam = separate OS process, unbound
      # client socket — dolphin's exact sending position.
      sender = """
      {:ok, s} = :socket.open(:local, :dgram, :default)
      dest = %{family: :local, path: "#{path}"}
      #{frames_script}
      IO.puts("done")
      """

      {out, 0} = System.cmd("elixir", ["-e", sender], stderr_to_stdout: true)
      assert out =~ "done"
    end

    test "mixed-size 60/s stream: every change message lands, last value wins", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [rng: "804D5F90"])
      :ok = MemoryWatcher.subscribe(w, :rng)
      path = Path.join(home, "MemoryWatcher/MemoryWatcher")

      # 50 iterations: real message then NUL, 8ms apart (~2x dolphin rate).
      external_stream(path, """
      for i <- 1..50 do
        hex = Integer.to_string(i, 16)
        :ok = :socket.sendto(s, "804D5F90\\n" <> hex <> "\\n\\0", dest)
        :ok = :socket.sendto(s, "\\0", dest)
        Process.sleep(8)
      end
      """)

      # EXPECT: all 50 change messages parsed; final value = 50.
      Process.sleep(300)
      assert MemoryWatcher.get(w, :rng) == {:ok, 50}

      received =
        Stream.repeatedly(fn ->
          receive do
            {:memory_watch, :rng, v} -> v
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert length(received) == 50, "expected 50 change notifications, got #{length(received)}"
      assert List.last(received) == 50
    end

    test "frame sizes survive verbatim (no truncation) across sizes 1..64", %{home: home} do
      {:ok, w} = MemoryWatcher.start_link(home: home, watches: [rng: "804D5F90"])
      path = Path.join(home, "MemoryWatcher/MemoryWatcher")

      # Payloads of increasing size; each parseable, value = the size.
      external_stream(path, """
      for n <- 1..64 do
        pad = String.duplicate(" ", n)
        _ = pad
        hex = Integer.to_string(n, 16)
        :ok = :socket.sendto(s, "804D5F90\\n" <> hex <> "\\n\\0", dest)
      end
      """)

      Process.sleep(300)
      # EXPECT: last message intact -> value 64. Truncation to "\\0"
      # would leave :unknown or a stale value.
      assert MemoryWatcher.get(w, :rng) == {:ok, 64}

      %{socket: info, raw_ring: ring} = MemoryWatcher.debug_info(w)
      assert info[:counters][:read_pkg] >= 64
      # The most recent raw frames must be full messages, not bare NULs.
      assert Enum.any?(ring, &(byte_size(&1) > 1)), "ring held only truncated frames: #{inspect(ring)}"
    end
  end
end