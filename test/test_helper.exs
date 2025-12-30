# Don't start the application during tests to avoid stdin blocking
Application.put_env(:ragex, :start_server, false)

ExUnit.start()
