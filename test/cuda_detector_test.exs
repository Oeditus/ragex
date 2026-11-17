defmodule Ragex.CudaDetectorTest do
  use ExUnit.Case, async: false

  alias Ragex.CudaDetector

  describe "cpu_only?/0" do
    test "returns true when EXLA_CPU_ONLY is 1 or true" do
      for val <- ["1", "true"] do
        System.put_env("EXLA_CPU_ONLY", val)
        assert CudaDetector.cpu_only?()
      end
    after
      System.delete_env("EXLA_CPU_ONLY")
    end

    test "returns true when XLA_TARGET is cpu" do
      System.put_env("XLA_TARGET", "cpu")
      assert CudaDetector.cpu_only?()
    after
      System.delete_env("XLA_TARGET")
    end

    test "returns false when CPU mode is not set" do
      System.delete_env("EXLA_CPU_ONLY")
      System.delete_env("XLA_TARGET")
      refute CudaDetector.cpu_only?()
    end
  end

  describe "configured_cuda?/0" do
    test "detects XLA_TARGET cuda values" do
      for target <- ["cuda", "cuda12", "cuda13"] do
        System.put_env("XLA_TARGET", target)
        assert CudaDetector.configured_cuda?()
      end
    after
      System.delete_env("XLA_TARGET")
    end

    test "detects RAGEX_EXLA_CLIENT" do
      System.put_env("RAGEX_EXLA_CLIENT", "cuda")
      assert CudaDetector.configured_cuda?()
    after
      System.delete_env("RAGEX_EXLA_CLIENT")
    end

    test "detects Application env for :ragex, :exla_client" do
      Application.put_env(:ragex, :exla_client, :cuda)
      assert CudaDetector.configured_cuda?()
    after
      Application.delete_env(:ragex, :exla_client)
    end
  end

  describe "deps_compilation?/0" do
    setup do
      previous_env = System.get_env("XLA_BUILD")
      previous_argv = System.argv()

      System.delete_env("XLA_BUILD")

      on_exit(fn ->
        if previous_env,
          do: System.put_env("XLA_BUILD", previous_env),
          else: System.delete_env("XLA_BUILD")

        System.argv(previous_argv)
      end)

      :ok
    end

    test "returns true when XLA_BUILD is set" do
      System.put_env("XLA_BUILD", "1")
      assert CudaDetector.deps_compilation?()
    end

    test "returns false when XLA_BUILD is empty" do
      System.put_env("XLA_BUILD", "")
      System.argv(["compile"])
      refute CudaDetector.deps_compilation?()
    end

    test "returns true for deps.* Mix tasks" do
      for task <- ["deps.get", "deps.compile", "deps.update"] do
        System.argv([task])
        assert CudaDetector.deps_compilation?(), "#{task} should be deps compilation"
      end
    end

    test "returns false for non-deps Mix tasks" do
      for task <- ["compile", "test", "run"] do
        System.argv([task])
        refute CudaDetector.deps_compilation?(), "#{task} should not be deps compilation"
      end
    end

    test "returns false when there are no arguments" do
      System.argv([])
      refute CudaDetector.deps_compilation?()
    end
  end

  describe "detect/0 and auto_configure/0" do
    test "detects GPU or returns no_gpu without crashing" do
      result = CudaDetector.detect()

      case result do
        {:ok, info} ->
          assert is_binary(info.target)
          assert info.target in ["cuda", "cuda12", "cuda13"]
          assert is_list(info.lib_dirs)

        :no_gpu ->
          assert true
      end
    end

    test "auto_configure respects explicit CPU mode" do
      System.put_env("EXLA_CPU_ONLY", "true")
      assert CudaDetector.auto_configure() == :cpu_only
    after
      System.delete_env("EXLA_CPU_ONLY")
    end

    test "auto_configure skips detection while compiling dependencies" do
      previous_argv = System.argv()
      previous_target = System.get_env("XLA_TARGET")

      try do
        System.delete_env("EXLA_CPU_ONLY")
        System.delete_env("XLA_TARGET")
        System.argv(["deps.compile"])

        assert CudaDetector.auto_configure() == :deps_compilation
        # The whole point: no environment mutation, so `xla` keeps building
        # for whatever target the caller asked for.
        assert System.get_env("XLA_TARGET") == nil
      after
        System.argv(previous_argv)

        if previous_target,
          do: System.put_env("XLA_TARGET", previous_target),
          else: System.delete_env("XLA_TARGET")
      end
    end
  end

  describe "cuda_usable?/0 and cuda_runtime_present?/0" do
    test "cuda_usable? is false in CPU-only mode" do
      System.put_env("EXLA_CPU_ONLY", "true")
      refute CudaDetector.cuda_usable?()
    after
      System.delete_env("EXLA_CPU_ONLY")
    end

    test "cuda_runtime_present? returns a boolean without crashing" do
      assert is_boolean(CudaDetector.cuda_runtime_present?())
    end
  end
end
