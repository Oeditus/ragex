defmodule Ragex.Embeddings.BumblebeeBackendTest do
  use ExUnit.Case, async: true

  test "CUDA detection checks device counts without creating a client or requiring native libraries" do
    root = Path.expand("../..", __DIR__)

    code = """
    Code.compiler_options(no_warn_undefined: :all)

    for module <- [Bumblebee, Nx, EXLA] do
      Module.create(module, quote(do: nil), Macro.Env.location(__ENV__))
    end

    defmodule EXLA.Client do
      def get_supported_platforms do
        case Process.get(:platforms) do
          :raise -> raise "NIF unavailable"
          :exit -> exit(:unavailable)
          platforms -> platforms
        end
      end

      def fetch!(_name) do
        send(self(), :client_created)
        raise "availability detection must not create a client"
      end
    end

    root = hd(System.argv())
    Code.require_file("lib/ragex/embeddings/behaviour.ex", root)
    Code.require_file("lib/ragex/embeddings/bumblebee.ex", root)

    for {platforms, expected} <- [
          {%{host: 24}, false},
          {%{host: 24, cuda: 0}, false},
          {%{cuda: -1}, false},
          {%{cuda: 1}, true},
          {%{cuda: 2}, true},
          {:raise, false},
          {:exit, false}
        ] do
      Process.put(:platforms, platforms)
      actual = Ragex.Embeddings.Bumblebee.cuda_available?()

      if actual != expected do
        raise "unexpected CUDA availability for \#{inspect(platforms)}: \#{inspect(actual)}"
      end

      receive do
        :client_created -> raise "CUDA probe attempted to create a client"
      after
        0 -> :ok
      end
    end
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-e", code, "--", root],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
