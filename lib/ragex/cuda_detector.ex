defmodule Ragex.CudaDetector do
  @moduledoc """
  Automatic GPU and CUDA detection for Ragex.

  Detects NVIDIA GPUs and CUDA toolkits/drivers, configuring `XLA_TARGET`,
  `RAGEX_EXLA_CLIENT`, `PATH`, and `LD_LIBRARY_PATH` so that EXLA and Bumblebee
  compile and run with CUDA acceleration automatically.

  ## Compile-time vs. runtime

  `XLA_TARGET` is read by the `xla` package at **dependency compile time** to
  pick which precompiled XLA archive to download. Setting it from the host
  environment therefore changes the build of `exla` itself and must be done
  before `mix deps.compile` runs -- `auto_configure/0` (invoked from `mix.exs`)
  is deliberately a no-op during dependency compilation, see
  `deps_compilation?/0`. Runtime clients are selected separately via
  `:ragex, :exla_client` / `RAGEX_EXLA_CLIENT`.
  """

  @doc """
  Runs GPU detection and configures environment and application settings for CUDA
  if a GPU is detected and CPU-only mode has not been explicitly requested.

  Returns `:deps_compilation` without touching the environment when called while
  Mix is compiling dependencies. `mix.exs` evaluates this module on every Mix
  invocation, including the dependency compilation of `xla`/`exla`, and writing
  `XLA_TARGET` at that point would flip their build target mid-run: `xla` would
  download the CUDA archive and `exla` would then fail to build against a
  precompiled CPU-only `xla_extension`. The build target must come from the
  caller's environment (or CI variables) instead.
  """
  @spec auto_configure() :: {:ok, map()} | :cpu_only | :no_gpu | :deps_compilation
  def auto_configure do
    cond do
      deps_compilation?() ->
        :deps_compilation

      cpu_only?() ->
        :cpu_only

      true ->
        case detect() do
          {:ok, info} ->
            apply_env(info)
            {:ok, info}

          error ->
            error
        end
    end
  end

  @doc """
  Returns `true` when the current Mix invocation is compiling dependencies
  (`mix deps.compile`, `mix deps.get`, `mix deps.update`, ...).

  Those tasks rebuild `xla`/`exla` from source, and their build target is
  decided by `XLA_TARGET` at that moment. Mutating the environment from
  `mix.exs` while they run produces a half-CUDA/half-CPU build that fails to
  compile, so detection is skipped for them.
  """
  @spec deps_compilation?() :: boolean()
  def deps_compilation? do
    xla_build?() or deps_task?()
  end

  defp xla_build? do
    case System.get_env("XLA_BUILD") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp deps_task? do
    case System.argv() do
      [task | _] when is_binary(task) -> String.starts_with?(task, "deps.")
      _ -> false
    end
  end

  @doc """
  Returns `true` if CPU-only mode is explicitly enforced via `EXLA_CPU_ONLY=true`
  or `XLA_TARGET=cpu`.
  """
  @spec cpu_only?() :: boolean()
  def cpu_only? do
    System.get_env("EXLA_CPU_ONLY") in ["1", "true"] or
      System.get_env("XLA_TARGET") == "cpu"
  end

  @doc """
  Returns `true` if CUDA has been configured in the environment or application.
  """
  @spec configured_cuda?() :: boolean()
  def configured_cuda? do
    System.get_env("XLA_TARGET") in ["cuda", "cuda12", "cuda13"] or
      System.get_env("RAGEX_EXLA_CLIENT") == "cuda" or
      Application.get_env(:ragex, :exla_client) == :cuda
  end

  @doc """
  Returns `true` if a CUDA GPU is available or configured, and CPU-only mode is not set.
  """
  @spec cuda_available?() :: boolean()
  def cuda_available? do
    not cpu_only?() and (configured_cuda?() or gpu_present?())
  end

  @doc """
  Detects NVIDIA hardware, CUDA toolkits, and library directories.
  """
  @spec detect() :: {:ok, map()} | :no_gpu
  def detect do
    if gpu_present?() do
      nvcc_path = find_nvcc()
      cuda_home = find_cuda_home(nvcc_path)
      target = infer_target(nvcc_path)
      lib_dirs = find_cuda_lib_dirs(cuda_home)

      bin_dir =
        cond do
          nvcc_path -> Path.dirname(nvcc_path)
          cuda_home -> Path.join(cuda_home, "bin")
          true -> nil
        end

      {:ok,
       %{
         target: target,
         nvcc: nvcc_path,
         cuda_home: cuda_home,
         bin_dir: bin_dir,
         lib_dirs: lib_dirs
       }}
    else
      :no_gpu
    end
  end

  @doc """
  Checks for the presence of NVIDIA GPU devices or drivers.
  """
  @spec gpu_present?() :: boolean()
  def gpu_present? do
    File.exists?("/dev/nvidia0") or
      File.exists?("/dev/nvidiactl") or
      File.exists?("/dev/nvhost-ctrl") or
      smi_present?()
  end

  defp smi_present? do
    case System.find_executable("nvidia-smi") do
      nil -> false
      smi -> match?({_, 0}, System.cmd(smi, ["-L"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  @doc """
  Finds the `nvcc` compiler executable in PATH or standard installation locations.
  """
  @spec find_nvcc() :: String.t() | nil
  def find_nvcc do
    case System.find_executable("nvcc") do
      nil ->
        candidates =
          Path.wildcard(
            Path.expand("~/.local/share/yoke/cuda*/lib/python*/site-packages/nvidia/cu*/bin/nvcc")
          ) ++
            [
              "/usr/local/cuda/bin/nvcc",
              "/opt/cuda/bin/nvcc",
              "/usr/bin/nvcc"
            ] ++
            Path.wildcard("/usr/local/cuda-*/bin/nvcc")

        Enum.find(candidates, &File.exists?/1)

      path ->
        path
    end
  rescue
    _ -> nil
  end

  @doc """
  Locates the CUDA root directory from environment variables, nvcc path, or standard paths.
  """
  @spec find_cuda_home(String.t() | nil) :: String.t() | nil
  def find_cuda_home(nvcc_path) do
    cond do
      env_home = System.get_env("CUDA_HOME") || System.get_env("CUDA_PATH") ->
        if File.dir?(env_home), do: env_home, else: nil

      nvcc_path ->
        Path.dirname(Path.dirname(nvcc_path))

      true ->
        candidates =
          Path.wildcard(
            Path.expand("~/.local/share/yoke/cuda*/lib/python*/site-packages/nvidia/cu*")
          ) ++
            ["/usr/local/cuda", "/opt/cuda"] ++
            Path.wildcard("/usr/local/cuda-*")

        Enum.find(candidates, &File.dir?/1)
    end
  rescue
    _ -> nil
  end

  @doc """
  Finds CUDA and companion library directories (libcudart, libcublas, libcudnn, libnccl, etc.).
  """
  @spec find_cuda_lib_dirs(String.t() | nil) :: [String.t()]
  def find_cuda_lib_dirs(cuda_home) do
    if cuda_home && File.dir?(cuda_home) do
      candidates = [
        Path.join(cuda_home, "lib"),
        Path.join(cuda_home, "lib64"),
        Path.join([cuda_home, "..", "cudnn", "lib"]),
        Path.join([cuda_home, "..", "nccl", "lib"]),
        Path.join([cuda_home, "..", "nvshmem", "lib"])
      ]

      candidates
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Infers the appropriate XLA target ("cuda13", "cuda12", or "cuda").
  """
  @spec infer_target(String.t() | nil) :: String.t()
  def infer_target(nvcc_path) do
    case System.get_env("XLA_TARGET") do
      target when is_binary(target) and target not in ["", "cpu"] ->
        target

      _ ->
        infer_from_nvcc(nvcc_path) || infer_from_smi() || "cuda13"
    end
  end

  defp infer_from_nvcc(nil), do: nil

  defp infer_from_nvcc(path) do
    case System.cmd(path, ["--version"]) do
      {output, 0} ->
        cond do
          output =~ "release 13." -> "cuda13"
          output =~ "release 12." -> "cuda12"
          true -> "cuda"
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp infer_from_smi do
    with smi when is_binary(smi) <- System.find_executable("nvidia-smi"),
         {output, 0} <- System.cmd(smi, []) do
      case Regex.run(~r/CUDA Version:\s*(\d+)\.(\d+)/, output) do
        [_, major, _minor] ->
          case String.to_integer(major) do
            v when v >= 13 -> "cuda13"
            12 -> "cuda12"
            _ -> "cuda"
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Returns `true` when a CUDA build of XLA is actually usable on this machine.

  A CUDA build of `exla` links against `libcudart`, so a GPU device alone is not
  enough: the CUDA runtime must also be resolvable at runtime. This guards
  `:ragex, :exla_client` so that a CUDA-targeted build on a host without the
  CUDA runtime degrades to the host CPU client instead of crashing on first use.

  Returns `false` in CPU-only mode.
  """
  @spec cuda_usable?() :: boolean()
  def cuda_usable? do
    not cpu_only?() and cuda_runtime_present?()
  end

  @doc """
  Returns `true` when the CUDA runtime library (`libcudart`) can be found on the
  standard linker paths, in `LD_LIBRARY_PATH`, or under a detected `CUDA_HOME`.
  """
  @spec cuda_runtime_present?() :: boolean()
  def cuda_runtime_present? do
    Enum.any?(cuda_runtime_candidates(), &File.exists?/1)
  rescue
    _ -> false
  end

  defp cuda_runtime_candidates do
    ld_paths =
      System.get_env("LD_LIBRARY_PATH", "")
      |> String.split(":", trim: true)

    home_dirs =
      case find_cuda_home(find_nvcc()) do
        nil -> []
        home -> find_cuda_lib_dirs(home)
      end

    (ld_paths ++ home_dirs ++ default_cuda_lib_dirs())
    |> Enum.uniq()
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, "libcudart.so*")) ++
        Path.wildcard(Path.join(dir, "libcudart.dylib")) ++
        Path.wildcard(Path.join(dir, "cudart64_*.dll"))
    end)
  end

  defp default_cuda_lib_dirs do
    [
      "/usr/local/cuda/lib64",
      "/usr/local/cuda/lib",
      "/usr/lib/x86_64-linux-gnu",
      "/usr/lib64",
      "/usr/lib"
    ] ++ Path.wildcard("/usr/local/cuda-*/lib64")
  end

  @doc """
  Applies detected CUDA configuration to environment variables and application config.
  """
  @spec apply_env(map()) :: :ok
  def apply_env(info) do
    if is_nil(System.get_env("XLA_TARGET")) or System.get_env("XLA_TARGET") == "" do
      System.put_env("XLA_TARGET", info.target)
    end

    if is_nil(System.get_env("RAGEX_EXLA_CLIENT")) or System.get_env("RAGEX_EXLA_CLIENT") == "" do
      System.put_env("RAGEX_EXLA_CLIENT", "cuda")
    end

    Application.put_env(:ragex, :exla_client, :cuda)

    if info.bin_dir && File.dir?(info.bin_dir) do
      prepend_path("PATH", info.bin_dir)
    end

    Enum.each(info.lib_dirs, fn dir ->
      prepend_path("LD_LIBRARY_PATH", dir)
    end)

    if info.cuda_home do
      if is_nil(System.get_env("CUDA_HOME")), do: System.put_env("CUDA_HOME", info.cuda_home)
      if is_nil(System.get_env("CUDA_PATH")), do: System.put_env("CUDA_PATH", info.cuda_home)

      case System.get_env("XLA_FLAGS") do
        nil ->
          System.put_env("XLA_FLAGS", "--xla_gpu_cuda_data_dir=#{info.cuda_home}")

        flags ->
          unless flags =~ "--xla_gpu_cuda_data_dir=" do
            System.put_env("XLA_FLAGS", "#{flags} --xla_gpu_cuda_data_dir=#{info.cuda_home}")
          end
      end
    end
  end

  defp prepend_path(var, dir) do
    current = System.get_env(var, "")
    entries = String.split(current, ":", trim: true)

    unless dir in entries do
      new_val = if current == "", do: dir, else: "#{dir}:#{current}"
      System.put_env(var, new_val)
    end
  end
end
