import Config

# Runtime Configuration
# This file is executed after compilation, allowing dynamic configuration

# Auto-analyze directories on startup
# Add directories that should be automatically analyzed when the application starts
# Example:
#   config :ragex, :auto_analyze_dirs, [
#     "/path/to/project1",
#     "/path/to/project2"
#   ]
dirs = "RAGEX_AUTO_ANALYZE_DIRS" |> System.get_env("") |> String.split(":", trim: true)

config :ragex, :auto_analyze_dirs, dirs

# You can also set this via config files in specific environments:
# config :ragex, :auto_analyze_dirs, [
#   "/opt/Proyectos/Ammotion/ragex"
# ]
