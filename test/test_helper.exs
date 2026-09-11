# Don't start the server during tests to avoid stdin blocking
Application.put_env(:ragex, :start_server, false)

{:ok, _} = Application.ensure_all_started(:ragex)

ExUnit.start(capture_log: true)

ExUnit.after_suite(fn _ ->
  Ragex.Dllb.ProjectManager.stop_all_instances()
end)
