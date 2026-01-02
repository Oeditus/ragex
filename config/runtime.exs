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
config :ragex,
       :auto_analyze_dirs,
       System.get_env("RAGEX_AUTO_ANALYZE_DIRS", "")
       |> String.split(":", trim: true)
       |> case do
  [] -> []
  dirs -> dirs
end

# You can also set this via config files in specific environments:
# config :ragex, :auto_analyze_dirs, [
#   "/opt/Proyectos/Ammotion/ragex"
# ]
