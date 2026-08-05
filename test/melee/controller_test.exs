defmodule Melee.ControllerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Melee.Controller

  doctest Melee.Controller

  @scratch System.tmp_dir!()

  # A controller writing to a regular file: same code path as the fifo,
  # but the written command stream can be read back deterministically.
  defp file_controller(ctx, opts \\ []) do
    path = Path.join(@scratch, "melee_ctl_#{ctx.test |> :erlang.phash2()}")
    File.rm(path)
    {:ok, pid} = Controller.start_link(Keyword.merge([pipe_path: path], opts))
    :ok = Controller.connect(pid)
    {pid, path}
  end

  defp written(pid, path) do
    # flush ordering: all casts are serialized before this call returns
    :ok = Controller.flush(pid)
    File.read!(path)
  end

  describe "analog quantization (golden values from Python libmelee)" do
    test "fix_analog_stick matches Python across the range" do
      assert Controller.fix_analog_stick(0.0) == 0.1854330708661417
      assert Controller.fix_analog_stick(0.25) == 0.34291338582677167
      assert Controller.fix_analog_stick(0.3) == 0.37440944881889765
      assert Controller.fix_analog_stick(0.5) == 0.5003937007874015
      # float representation pushes the raw value just past the .5 boundary
      assert Controller.fix_analog_stick(0.503125) == 0.5043307086614173
      assert Controller.fix_analog_stick(0.7) == 0.6263779527559055
      assert Controller.fix_analog_stick(0.75) == 0.6578740157480315
      assert Controller.fix_analog_stick(1.0) == 0.8153543307086614
    end

    test "fix_analog_trigger matches Python across the range" do
      assert Controller.fix_analog_trigger(0.0) == 0.0003921568627450981
      assert Controller.fix_analog_trigger(0.35) == 0.19254901960784315
      assert Controller.fix_analog_trigger(0.5) == 0.2749019607843137
      assert Controller.fix_analog_trigger(1.0) == 0.5494117647058824
    end

    property "fix_analog_stick maps [0,1] into a bounded band, monotonically" do
      check all(
              x <- StreamData.float(min: 0.0, max: 1.0),
              y <- StreamData.float(min: 0.0, max: 1.0)
            ) do
        fixed_x = Controller.fix_analog_stick(x)
        assert fixed_x >= 0.18 and fixed_x <= 0.82

        if x <= y do
          assert fixed_x <= Controller.fix_analog_stick(y)
        end
      end
    end

    property "fix_analog_trigger stays within [0, 0.55]" do
      check all(x <- StreamData.float(min: 0.0, max: 1.0)) do
        fixed = Controller.fix_analog_trigger(x)
        assert fixed >= 0.0 and fixed <= 0.55
      end
    end
  end

  describe "command protocol" do
    test "press and release write libmelee's exact commands", ctx do
      {pid, path} = file_controller(ctx)
      Controller.press_button(pid, :a)
      Controller.press_button(pid, :d_up)
      Controller.release_button(pid, :a)

      assert written(pid, path) == "PRESS A\nPRESS D_UP\nRELEASE A\nFLUSH\n"
    end

    test "tilt_analog writes quantized SET commands", ctx do
      {pid, path} = file_controller(ctx)
      Controller.tilt_analog(pid, :main, 0.5, 1.0)
      Controller.tilt_analog(pid, :c, 0.0, 0.5)

      assert written(pid, path) ==
               "SET MAIN 0.5003937007874015 0.8153543307086614\n" <>
                 "SET C 0.1854330708661417 0.5003937007874015\nFLUSH\n"
    end

    test "tilt_analog without fix writes raw values", ctx do
      {pid, path} = file_controller(ctx, fix_analog_inputs: false)
      Controller.tilt_analog(pid, :main, 0.25, 0.75)

      assert written(pid, path) == "SET MAIN 0.25 0.75\nFLUSH\n"
    end

    test "press_shoulder writes SET L with quantized amount", ctx do
      {pid, path} = file_controller(ctx)
      Controller.press_shoulder(pid, :l, 1.0)

      assert written(pid, path) == "SET L 0.5494117647058824\nFLUSH\n"
    end

    test "release_all writes the full reset block", ctx do
      {pid, path} = file_controller(ctx)
      Controller.release_all(pid)

      assert written(pid, path) ==
               "RELEASE A\nRELEASE B\nRELEASE X\nRELEASE Y\nRELEASE Z\n" <>
                 "RELEASE L\nRELEASE R\nRELEASE START\nRELEASE D_UP\n" <>
                 "RELEASE D_DOWN\nRELEASE D_LEFT\nRELEASE D_RIGHT\n" <>
                 "SET MAIN .5 .5\nSET C .5 .5\nSET L 0\nSET R 0\nFLUSH\n"
    end

    test "simple_press tilts, clears shoulders, presses one button", ctx do
      {pid, path} = file_controller(ctx)
      Controller.simple_press(pid, 1.0, 0.5, :b)
      output = written(pid, path)

      assert output =~ "SET MAIN 0.8153543307086614 0.5003937007874015\n"
      assert output =~ "PRESS B\n"
      refute output =~ "PRESS A"
      assert output =~ "RELEASE A\n"
      assert String.ends_with?(output, "FLUSH\n")
    end
  end

  describe "state tracking" do
    test "current reflects unflushed presses; prev advances on flush", ctx do
      {pid, _path} = file_controller(ctx)

      Controller.press_button(pid, :a)
      Controller.tilt_analog(pid, :main, 1.0, 0.5)

      current = Controller.current(pid)
      assert current.button.a
      assert {x, _} = current.main_stick
      assert x > 0.8

      refute Controller.prev(pid).button.a
      :ok = Controller.flush(pid)
      assert Controller.prev(pid).button.a
    end

    test "release_all resets current to neutral", ctx do
      {pid, _path} = file_controller(ctx)
      Controller.press_button(pid, :x)
      Controller.press_shoulder(pid, :r, 0.8)
      Controller.release_all(pid)

      assert Controller.current(pid) == Melee.ControllerState.neutral()
    end

    test "before connect, state updates but writes are dropped", ctx do
      path = Path.join(@scratch, "melee_ctl_unconnected_#{:erlang.phash2(ctx.test)}")
      File.rm(path)
      {:ok, pid} = Controller.start_link(pipe_path: path)

      Controller.press_button(pid, :a)
      :ok = Controller.flush(pid)

      assert Controller.current(pid).button.a
      refute File.exists?(path)
    end
  end

  describe "against a real fifo" do
    @tag :fifo
    test "commands arrive through a named pipe", ctx do
      path = Path.join(@scratch, "melee_fifo_#{:erlang.phash2(ctx.test)}")
      File.rm(path)
      {_, 0} = System.cmd("mkfifo", [path])

      reader =
        Task.async(fn ->
          {:ok, dev} = File.open(path, [:read, :raw])
          result = IO.binread(dev, :eof)
          File.close(dev)
          result
        end)

      {:ok, pid} = Controller.start_link(pipe_path: path)
      :ok = Controller.connect(pid, 5_000)
      Controller.press_button(pid, :a)
      :ok = Controller.flush(pid)
      :ok = Controller.disconnect(pid)

      assert Task.await(reader, 5_000) == "PRESS A\nFLUSH\n"
      File.rm(path)
    end
  end
end
