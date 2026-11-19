defmodule Ragex.Embeddings.BumblebeeBackendTest do
  use ExUnit.Case, async: true

  test "CUDA detection and serving selection respect supported platforms without creating a client" do
    root = Path.expand("../..", __DIR__)

    code = """
    Code.compiler_options(no_warn_undefined: :all)

    for module <- [Nx, EXLA] do
      Module.create(module, quote(do: nil), Macro.Env.location(__ENV__))
    end

    defmodule Bumblebee do
      def load_tokenizer(_repo), do: {:ok, :tokenizer}
      def load_model(_repo, _opts), do: {:ok, :model}
    end

    defmodule Bumblebee.Text.TextEmbedding do
      def text_embedding(:model, :tokenizer, opts), do: opts[:defn_options]
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

    :ets.new(:ragex_embedding_readiness, [:named_table, :set])
    model_info = %{repo: "test/model", max_tokens: 512}

    for {requested, platforms, expected} <- [
          {:cuda, %{host: 1}, :host},
          {"cuda", %{host: 1, cuda: 0}, :host},
          {:cuda, :raise, :host},
          {:cuda, :exit, :host},
          {:cuda, %{host: 1, cuda: 1}, :cuda},
          {:host, %{host: 1, cuda: 1}, :host}
        ] do
      Process.put(:platforms, platforms)
      Application.put_env(:ragex, :exla_client, requested)

      {:noreply, state} =
        Ragex.Embeddings.Bumblebee.handle_info({:load_model, model_info}, %{})

      unless state.ready and state.serving == [compiler: EXLA, client: expected] do
        raise "incorrect client selection: \#{inspect(state)}"
      end

      receive do
        :client_created -> raise "serving selection attempted to create a client"
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
