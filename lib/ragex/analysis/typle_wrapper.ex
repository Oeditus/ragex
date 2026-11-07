defmodule Ragex.Analysis.TypleWrapper do
  @moduledoc false

  case Code.ensure_compiled(Typle) do
    {:module, Typle} ->
      @spec types_for_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
      def types_for_file(file, opts), do: Typle.types_for_file(file, opts)

      @spec return_type(module(), atom(), non_neg_integer(), keyword()) :: Typle.Type.t()
      def return_type(mod, fun, arity, opts \\ []), do: Typle.return_type(mod, fun, arity, opts)

      @spec type_to_string(Typle.Type.t()) :: String.t()
      def type_to_string(type), do: Typle.Type.to_string(type)

    _ ->
      @spec types_for_file(String.t(), keyword()) :: {:error, :typle_not_available}
      def types_for_file(_file, _opts), do: {:error, :typle_not_available}

      @spec return_type(module(), atom(), non_neg_integer(), keyword()) :: nil
      def return_type(_mod, _fun, _arity, _opts), do: nil

      @spec type_to_string(any()) :: String.t()
      def type_to_string(type), do: to_string(type)
  end
end
