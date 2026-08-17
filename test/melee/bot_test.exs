defmodule Melee.BotTest do
  use ExUnit.Case, async: true

  defmodule NoopBot do
    use Melee.Bot

    @impl true
    def act(_me, _gamestate, _controller), do: :ok
  end

  test "a port spec colliding with the bot's own port raises" do
    # The raise happens while assembling specs, before any session is
    # launched.
    assert_raise ArgumentError, ~r/collides with the bot's own port/, fn ->
      Melee.Bot.run(NoopBot,
        port: 1,
        character: :fox,
        stage: :final_destination,
        p1: [character: :marth]
      )
    end
  end
end
