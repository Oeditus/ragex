# Don't start the application during tests to avoid stdin blocking
Application.put_env(:ragex, :start_server, false)

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  Ragex.Dllb.ProjectManager.stop_all_instances()
end)
