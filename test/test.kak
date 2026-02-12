# Source and require the manager logic
source "pluk.kak"
require-module pluk

# Configure the manager
set-option global pluk_install_dir "test/plugins"

# Run the setup
pluk-setup %{
    # A plugin with no config block
    "mawww/kakoune-gdb"

    # A plugin with a config block
    "andreyorst/fzf.kak" %{
        set-option global fzf_preview_width '50%'
        map global user f ': fzf-mode<ret>' -docstring 'fzf mode'
    }
}
