defmodule Ragex.Editor.Validators.Javascript do
  @moduledoc """
  JavaScript/TypeScript code validator.

  Uses Node.js to validate JavaScript/TypeScript syntax via
  `Ragex.Editor.Validators.Subprocess`. Requires Node.js to be installed on
  the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Validators.Subprocess

  @impl true
  def validate(content, _opts \\ []) do
    Subprocess.validate(content, spec())
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    ext = Path.extname(path)
    ext in [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"]
  end

  def can_validate?(_), do: false

  # Private

  defp spec do
    [
      extension: ".js",
      bin: "node",
      missing_message: "Node.js not found. Please install Node.js to validate JavaScript files.",
      command: fn path, _content -> {"node", ["-e", script(path)], []} end
    ]
  end

  # Uses @babel/parser (supporting TypeScript, JSX, and ES Modules) when
  # available, falling back to vm.Script otherwise.
  defp script(path) do
    """
    const fs = require('fs');
    const vm = require('vm');
    const path = require('path');
    const os = require('os');

    function loadBabel() {
      const candidates = [
        process.env.NODE_PATH,
        path.join(os.homedir(), '.local', 'share', 'mise', 'installs', 'node', 'latest', 'lib', 'node_modules')
      ].filter(Boolean);
      try { return require('@babel/parser'); } catch (_) {}
      for (const entry of candidates) {
        for (const dir of entry.split(path.delimiter)) {
          if (!dir) continue;
          try { return require(path.join(dir, '@babel/parser')); } catch (_) {}
        }
      }
      return null;
    }

    try {
        const code = fs.readFileSync('#{escape_path(path)}', 'utf8');
        const babel = loadBabel();
        if (babel) {
            babel.parse(code, {
                sourceType: 'module',
                allowImportExportEverywhere: true,
                allowReturnOutsideFunction: true,
                allowSuperOutsideMethod: true,
                allowUndeclaredExports: true,
                plugins: [
                    'typescript',
                    'jsx',
                    'classProperties',
                    'classPrivateProperties',
                    'classPrivateMethods',
                    'decorators-legacy',
                    'dynamicImport',
                    'asyncGenerators',
                    'exportDefaultFrom',
                    'topLevelAwait'
                ]
            });
        } else {
            new vm.Script(code);
        }
        console.log('VALID');
        process.exit(0);
    } catch (e) {
        if (e instanceof SyntaxError || (e && e.loc)) {
            if (e.loc) {
                console.log(`SYNTAX_ERROR:${e.loc.line}:${e.loc.column}:${e.message}`);
            } else {
                const match = e.stack && e.stack.match(/:([0-9]+):([0-9]+)/);
                if (match) {
                    console.log(`SYNTAX_ERROR:${match[1]}:${match[2]}:${e.message}`);
                } else {
                    console.log(`SYNTAX_ERROR:1:0:${e.message}`);
                }
            }
            process.exit(1);
        } else {
            console.log(`ERROR:${e.message}`);
            process.exit(1);
        }
    }
    """
  end

  defp escape_path(path) do
    String.replace(path, "'", "\\'")
  end
end
