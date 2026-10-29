defmodule Ragex.Embeddings.BumblebeeReadinessTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory
  alias Ragex.Embeddings.Bumblebee

  setup_all do
    supervisor = Process.whereis(Ragex.Supervisor)
    running? = Process.whereis(Bumblebee) != nil

    if running? do
      :ok = Supervisor.terminate_child(supervisor, Bumblebee)
    end

    on_exit(fn ->
      if running?, do: Supervisor.restart_child(supervisor, Bumblebee)
    end)

    :ok
  end

  test "readiness returns immediately while the model loader is busy" do
    pid = start_busy_model()
    task = Task.async(fn -> Bumblebee.ready?() end)

    try do
      assert Task.yield(task, 250) == {:ok, false}
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "readiness is readable during inference and disappears on process exit" do
    pid = start_busy_model()
    send(pid, {:ready, self()})
    assert_receive :ready
    task = Task.async(fn -> Bumblebee.ready?() end)

    try do
      assert Task.yield(task, 250) == {:ok, true}
    after
      Task.shutdown(task, :brutal_kill)
    end

    stop_model(pid)
    refute Bumblebee.ready?()
    start_busy_model()
    refute Bumblebee.ready?()
  end

  test "source indexing completes without waiting for model initialization" do
    start_busy_model()

    file =
      Path.join(System.tmp_dir!(), "ragex_model_loading_#{System.unique_integer([:positive])}.ex")

    File.write!(file, "defmodule ModelLoadingIndexTest do\n  def value, do: :ok\nend\n")
    on_exit(fn -> File.rm(file) end)

    task =
      Task.async(fn ->
        Directory.analyze_files([file],
          notify: false,
          persist: false,
          timeout: 1000
        )
      end)

    try do
      assert {:ok, {:ok, %{success: 1, errors: 0}}} = Task.yield(task, 2000)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp start_busy_model do
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), Bumblebee)
        {:ok, _state} = Bumblebee.init([])

        receive do
          {:load_model, _info} -> :ok
        end

        send(parent, :started)
        busy_model_loop()
      end)

    on_exit(fn -> stop_model(pid) end)
    assert_receive :started
    pid
  end

  defp busy_model_loop do
    receive do
      {:ready, caller} ->
        :ets.insert(:ragex_embedding_readiness, {:ready, true})
        send(caller, :ready)
        busy_model_loop()
    end
  end

  defp stop_model(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end
end
