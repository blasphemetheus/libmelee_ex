# The spectator-port probe (Melee.Dolphin check_spectator_port) is
# machine-environment-sensitive: any real Dolphin on this box holding
# 51441 would fail every prepare_home test. Off by default in tests;
# the invariant's own tests re-enable it per call.
Application.put_env(:melee, :check_spectator_port, false)

ExUnit.start(exclude: [:dolphin])
