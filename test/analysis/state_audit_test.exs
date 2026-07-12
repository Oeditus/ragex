defmodule Ragex.Analysis.StateAuditTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.StateAudit

  @clean_genserver """
  defmodule CleanServer do
    use GenServer

    defstruct [:data]

    def init(args) do
      {:ok, %CleanServer{data: args}}
    end

    def handle_call(:get, _from, state) do
      {:reply, state.data, state}
    end
  end
  """

  @bad_state_genserver """
  defmodule BadStateServer do
    use GenServer

    def init(args) do
      {:ok, %{data: args}}
    end
  end
  """

  @deadlock_genserver """
  defmodule DeadlockServer do
    use GenServer

    defstruct [:data]

    def init(args) do
      {:ok, %DeadlockServer{data: args}}
    end

    def handle_cast({:update, other_pid}, state) do
      val = GenServer.call(other_pid, :get_val)
      {:noreply, %{state | data: val}}
    end
  end
  """

  describe "audit_file/1" do
    test "passes clean GenServer without issues" do
      tmp_file = Path.join(System.tmp_dir!(), "clean_server_#{:rand.uniform(100_000)}.ex")
      File.write!(tmp_file, @clean_genserver)

      assert {:ok, result} = StateAudit.audit_file(tmp_file)
      assert result.genserver? == true
      refute result.has_issues?
      assert result.issues == []

      File.rm(tmp_file)
    end

    test "detects raw map state initialization" do
      tmp_file = Path.join(System.tmp_dir!(), "bad_state_server_#{:rand.uniform(100_000)}.ex")
      File.write!(tmp_file, @bad_state_genserver)

      assert {:ok, result} = StateAudit.audit_file(tmp_file)
      assert result.genserver? == true
      assert result.has_issues?
      assert Enum.any?(result.issues, &(&1.type == :unstructured_state))

      File.rm(tmp_file)
    end

    test "detects GenServer.call inside cast callback" do
      tmp_file = Path.join(System.tmp_dir!(), "deadlock_server_#{:rand.uniform(100_000)}.ex")
      File.write!(tmp_file, @deadlock_genserver)

      assert {:ok, result} = StateAudit.audit_file(tmp_file)
      assert result.genserver? == true
      assert result.has_issues?
      assert Enum.any?(result.issues, &(&1.type == :sync_call_in_callback))

      File.rm(tmp_file)
    end
  end
end
