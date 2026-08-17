defmodule Melee.BotTest do
  use ExUnit.Case, async: true

  defmodule NoopBot do
    use Melee.Bot

    @impl true
    def act(_me, _gamestate, _controller), do: :ok
  end

  test "a port spec colliding with a bot's port raises" do
    # The raise happens while assembling specs, before any session is
    # launched.
    assert_raise ArgumentError, ~r/collides with a bot's port/, fn ->
      Melee.Bot.run(NoopBot,
        port: 1,
        character: :fox,
        stage: :final_destination,
        p1: [character: :marth]
      )
    end
  end

  test "two bots sharing a port raises" do
    assert_raise ArgumentError, ~r/share a port/, fn ->
      Melee.Bot.run_many(
        [
          {NoopBot, port: 1, character: :fox},
          {NoopBot, port: 1, character: :falco}
        ],
        stage: :final_destination
      )
    end
  end
end
