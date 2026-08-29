defmodule Mix.Tasks.Ragex.InstallMan do
  @moduledoc """
  Install Ragex man pages.

  ## Usage

      # Show man pages and installation instructions
      mix ragex.install_man
      
      # Install man pages (requires sudo)
      mix ragex.install_man --install

  Installs comprehensive man pages for Ragex commands to
  /usr/local/share/man/man1/ for system-wide access.
  """

  @shortdoc "Install man pages"

  use Mix.Task

  alias Ragex.CLI.{Colors, Output}

  @man_dir Path.join(:code.priv_dir(:ragex), "man")
  @install_dir "/usr/local/share/man/man1"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [install: :boolean, help: :boolean],
        aliases: [i: :install, h: :help]
      )

    cond do
      opts[:help] ->
        show_help()

      opts[:install] ->
        install_man_pages()

      true ->
        show_man_pages()
    end
  end

  defp show_man_pages do
    Output.section("Ragex Man Pages")

    IO.puts(Colors.muted("Available man pages:"))
    IO.puts("")

    man_files = list_man_files()

    for file <- man_files do
      name = Path.basename(file, ".1")
      IO.puts("  • #{Colors.info(name)}(1)")
    end

    IO.puts("")
    IO.puts(Colors.bold("Installation:"))
    IO.puts("")
    IO.puts("  Run: #{Colors.highlight("mix ragex.install_man --install")}")
    IO.puts("  Or manually: #{Colors.highlight("sudo cp #{@man_dir}/*.1 #{@install_dir}/")}")
    IO.puts("")
    IO.puts(Colors.muted("After installation, view with: #{Colors.highlight("man ragex")}"))
    IO.puts("")
  end

  defp install_man_pages do
    Output.section("Install Man Pages")

    man_files = list_man_files()

    if man_files == [] do
      IO.puts(Colors.error("󰅖 No man pages found in #{@man_dir}"))
      IO.puts("")
      System.halt(1)
    end

    IO.puts(Colors.info("Found #{length(man_files)} man page(s)"))
    IO.puts("")

    # Check if install directory exists
    unless File.dir?(@install_dir) do
      IO.puts(Colors.warning("󰀦 Install directory does not exist: #{@install_dir}"))
      IO.puts(Colors.error("󰅖 Installation requires sudo to create directory"))
      IO.puts("")
      IO.puts("Run manually:")
      IO.puts(Colors.highlight("  sudo mkdir -p #{@install_dir}"))

      for file <- man_files do
        dest = Path.join(@install_dir, Path.basename(file))
        IO.puts(Colors.highlight("  sudo cp #{file} #{dest}"))
      end

      IO.puts("")
      System.halt(1)
    end

    # Attempt to install each man page
    results =
      for file <- man_files do
        dest = Path.join(@install_dir, Path.basename(file))

        case File.cp(file, dest) do
          :ok ->
            IO.puts(Colors.success("󰄬 Installed: #{Path.basename(file)}"))
            :ok

          {:error, :eacces} ->
            IO.puts(Colors.error("󰅖 Permission denied: #{Path.basename(file)}"))
            {:error, :eacces}

          {:error, reason} ->
            IO.puts(
              Colors.error("󰅖 Failed to install #{Path.basename(file)}: #{inspect(reason)}")
            )

            {:error, reason}
        end
      end

    IO.puts("")

    if Enum.all?(results, &(&1 == :ok)) do
      IO.puts(Colors.success("󰄬 All man pages installed successfully"))
      IO.puts("")
      show_usage_instructions()
    else
      IO.puts(Colors.error("󰅖 Some installations failed (permission denied)"))
      IO.puts("")
      IO.puts("Run with sudo:")

      for file <- man_files do
        dest = Path.join(@install_dir, Path.basename(file))
        IO.puts(Colors.highlight("  sudo cp #{file} #{dest}"))
      end

      IO.puts("")
      System.halt(1)
    end
  end

  defp list_man_files do
    if File.dir?(@man_dir) do
      Path.wildcard(Path.join(@man_dir, "*.1"))
      |> Enum.sort()
    else
      []
    end
  end

  defp show_usage_instructions do
    IO.puts(Colors.bold("Usage:"))
    IO.puts("  View main manual: #{Colors.highlight("man ragex")}")
    IO.puts("  View command manual: #{Colors.highlight("man ragex-refactor")}")
    IO.puts("  Search manuals: #{Colors.highlight("man -k ragex")}")
    IO.puts("")
    IO.puts(Colors.muted("Note: You may need to run 'mandb' to update the man page index"))
    IO.puts("")
  end

  defp show_help do
    IO.puts("""
    #{Colors.bold("Ragex Man Page Installer")}

    #{Colors.info("Show available man pages:")}
      mix ragex.install_man

    #{Colors.info("Install man pages (requires sudo):")}
      mix ragex.install_man --install

    #{Colors.info("Manual installation:")}
      sudo cp #{@man_dir}/*.1 #{@install_dir}/
      sudo mandb

    #{Colors.info("View installed man pages:")}
      man ragex
      man ragex-refactor
      man ragex-configure

    #{Colors.muted("Man pages provide comprehensive documentation for all Ragex commands.")}
    """)
  end
end
