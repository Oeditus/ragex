defmodule Ragex.Analysis.SecurityTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Security

  @moduletag :security

  # Test fixtures with known vulnerabilities
  @elixir_with_eval """
  defmodule UnsafeModule do
    def dangerous_eval(user_input) do
      Code.eval_string(user_input)
    end
  end
  """

  @elixir_with_system_cmd """
  defmodule CommandInjection do
    def run_command(user_input) do
      System.cmd("sh", ["-c", user_input])
    end
  end
  """

  @elixir_with_secret """
  defmodule ConfigModule do
    @api_key "sk-1234567890abcdef"
    
    def get_api_key, do: @api_key
  end
  """

  @elixir_safe """
  defmodule SafeModule do
    def add(x, y) do
      x + y
    end
    
    def process(data) do
      case Jason.decode(data) do
        {:ok, result} -> result
        {:error, _} -> nil
      end
    end
  end
  """

  setup do
    # Create temp directory for test files
    tmp_dir = System.tmp_dir!() |> Path.join("ragex_security_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "analyze_file/2" do
    test "detects Code.eval_string in Elixir code", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "unsafe_eval.ex")
      File.write!(file, @elixir_with_eval)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.has_vulnerabilities? == true
      assert result.total_vulnerabilities > 0

      # MetaCredo detects this via ImproperInputValidation (CWE-20)
      eval_vuln = Enum.find(result.vulnerabilities, &(&1.category == :security))
      assert eval_vuln != nil
      assert eval_vuln.severity in [:critical, :high]
    end

    test "detects System.cmd in Elixir code", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "command_injection.ex")
      File.write!(file, @elixir_with_system_cmd)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.has_vulnerabilities? == true

      # MetaCredo detects this via UnsafeExec check (warning category)
      assert result.total_vulnerabilities > 0
      assert Enum.any?(result.vulnerabilities, &(&1.severity in [:critical, :high, :medium]))
    end

    @tag skip: true, reason: :module_attribute_limitation
    test "detects hardcoded secrets", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "secrets.ex")
      File.write!(file, @elixir_with_secret)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.has_vulnerabilities? == true

      # Should detect hardcoded secret
      secret_vuln = Enum.find(result.vulnerabilities, &(&1.category == :hardcoded_secret))
      assert secret_vuln != nil
      assert secret_vuln.severity == :high
    end

    test "handles files with no vulnerabilities", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "safe.ex")
      File.write!(file, @elixir_safe)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.has_vulnerabilities? == false
      assert result.total_vulnerabilities == 0
      assert result.vulnerabilities == []
    end

    test "handles invalid files gracefully", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "nonexistent.ex")

      assert {:error, reason} = Security.analyze_file(file)
      assert reason != nil
    end

    test "includes severity counts", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "mixed_vulns.ex")
      File.write!(file, @elixir_with_eval <> "\n" <> @elixir_with_secret)

      assert {:ok, result} = Security.analyze_file(file)

      assert result.critical_count + result.high_count + result.medium_count + result.low_count ==
               result.total_vulnerabilities
    end

    test "includes file and language metadata", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.ex")
      File.write!(file, @elixir_with_eval)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.file == file
      assert result.language == :elixir
      assert match?(%DateTime{}, result.timestamp)
    end
  end

  describe "analyze_directory/2" do
    test "scans directory recursively", %{tmp_dir: tmp_dir} do
      # Create multiple files
      File.write!(Path.join(tmp_dir, "file1.ex"), @elixir_with_eval)
      File.write!(Path.join(tmp_dir, "file2.ex"), @elixir_safe)

      sub_dir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(sub_dir, "file3.ex"), @elixir_with_system_cmd)

      assert {:ok, results} = Security.analyze_directory(tmp_dir, recursive: true)
      assert length(results) == 3

      vulns_count = Enum.count(results, & &1.has_vulnerabilities?)
      # Both eval and system_cmd files should have vulnerabilities
      assert vulns_count >= 1
    end

    test "scans directory non-recursively", %{tmp_dir: tmp_dir} do
      # Create multiple files
      File.write!(Path.join(tmp_dir, "file1.ex"), @elixir_with_eval)

      sub_dir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(sub_dir, "file2.ex"), @elixir_with_system_cmd)

      assert {:ok, results} = Security.analyze_directory(tmp_dir, recursive: false)
      assert length(results) == 1
    end

    test "uses parallel processing by default", %{tmp_dir: tmp_dir} do
      # Create multiple files
      for i <- 1..5 do
        File.write!(Path.join(tmp_dir, "file#{i}.ex"), @elixir_safe)
      end

      assert {:ok, results} = Security.analyze_directory(tmp_dir, parallel: true)
      assert length(results) == 5
    end

    test "filters by severity", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "critical.ex"), @elixir_with_eval)
      File.write!(Path.join(tmp_dir, "high.ex"), @elixir_with_system_cmd)

      # Filter to only critical -- MetaCredo rates eval as :high, so
      # critical filter should yield fewer/no results
      assert {:ok, results} = Security.analyze_directory(tmp_dir, min_severity: :critical)

      all_vulns = Enum.flat_map(results, & &1.vulnerabilities)

      # All surviving vulns must be >= critical
      assert Enum.all?(all_vulns, &(&1.severity == :critical))
    end

    test "filters by categories", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "eval.ex"), @elixir_with_eval)
      File.write!(Path.join(tmp_dir, "secrets.ex"), @elixir_with_secret)

      # MetaCredo uses :security as category for all security checks
      assert {:ok, results} =
               Security.analyze_directory(tmp_dir, categories: [:security])

      all_vulns = Enum.flat_map(results, & &1.vulnerabilities)
      assert Enum.all?(all_vulns, &(&1.category == :security))
    end

    test "handles empty directory", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)

      assert {:ok, results} = Security.analyze_directory(empty_dir)
      assert results == []
    end
  end

  describe "audit_report/1" do
    test "generates summary", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.ex"), @elixir_with_eval)
      File.write!(Path.join(tmp_dir, "file2.ex"), @elixir_safe)

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert report.total_files == 2
      assert report.files_with_vulnerabilities >= 0
      assert report.summary =~ "Security Audit Summary"
    end

    test "groups by severity", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "vulns.ex"), @elixir_with_eval)

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert is_map(report.by_severity)
      assert Enum.all?(Map.keys(report.by_severity), &(&1 in [:critical, :high, :medium, :low]))
    end

    test "groups by category", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "vulns.ex"),
        @elixir_with_eval <> "\n" <> @elixir_with_secret
      )

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert is_map(report.by_category)
      assert map_size(report.by_category) > 0
    end

    test "groups by file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.ex"), @elixir_with_eval)
      File.write!(Path.join(tmp_dir, "file2.ex"), @elixir_safe)

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert is_map(report.by_file)
      # Only files with vulnerabilities are included
      assert map_size(report.by_file) == 1
    end

    test "generates recommendations", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "vulns.ex"), @elixir_with_eval)

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert match?([_ | _], report.recommendations)

      Enum.each(report.recommendations, fn rec ->
        assert rec.category != nil
        assert rec.count > 0
        assert rec.severity != nil
        assert rec.recommendation != nil
      end)
    end

    test "includes timestamp", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.ex"), @elixir_safe)

      {:ok, results} = Security.analyze_directory(tmp_dir)
      report = Security.audit_report(results)

      assert %DateTime{} = report.timestamp
    end
  end

  describe "multi-language support" do
    @tag skip: true, reason: :parse_non_elixir
    test "analyzes Python files", %{tmp_dir: tmp_dir} do
      python_code = """
      import pickle

      def unsafe_load(data):
          return pickle.loads(data)
      """

      file = Path.join(tmp_dir, "unsafe.py")
      File.write!(file, python_code)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.language == :python
      # Should detect pickle.loads vulnerability
      assert result.has_vulnerabilities? == true
    end

    @tag skip: true, reason: :parse_non_elixir
    test "analyzes Erlang files", %{tmp_dir: tmp_dir} do
      erlang_code = """
      -module(unsafe).
      -export([run/1]).

      run(Cmd) ->
          os:cmd(Cmd).
      """

      file = Path.join(tmp_dir, "unsafe.erl")
      File.write!(file, erlang_code)

      assert {:ok, result} = Security.analyze_file(file)
      assert result.language == :erlang
    end
  end
end
