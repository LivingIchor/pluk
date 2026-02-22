# Source and require the manager logic
source "pluk.kak"
require-module pluk

# Configure the manager
set-option global pluk_install_dir "test/plugins"

# Run the setup
pluk-setup %{
    # A plugin with no config block
    pluk "mawww/kakoune-gdb"

    # A plugin with a config block
    pluk "andreyorst/fzf.kak" %{
        set-option global fzf_preview_width '50%'
        map global user f ': fzf-mode<ret>' -docstring 'fzf mode'
    }

    # A plugin with install hook
    pluk "kak-lsp/kak-lsp" %{
        pluk-install-hook %{
            # Any shell code that needs to be run goes here...
            cargo install --locked --force --path .
        }

        # Configure here...
        map global user l %{:enter-user-mode lsp<ret>} -docstring "LSP mode"
    }
}
