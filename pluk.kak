# =============================================================================
# PUBLIC OPTIONS
# =============================================================================
declare-option -docstring "Plugin installation directory" \
    str pluk_install_dir "$HOME/.local/share/kak/plugins"

# =============================================================================
# INTERNAL STATE
# =============================================================================
declare-option -hidden str _pluk_dir

# =============================================================================
# MODULE
# =============================================================================
provide-module pluk %{
    # Initialize the path once when required
    evaluate-commands %sh{
        dir=$(dirname "$kak_source")
        printf "set-option global _pluk_dir '%s'" "$dir"
    }

    define-command pluk-setup -params 1 %{
        evaluate-commands %sh{
            # Set logging location
            logfile="${kak_opt__pluk_dir}/pluk.log"

            # Add all pluk options to shell environment
            echo "
                $kak_opt_pluk_install_dir
            " >/dev/null

            # Capture every environment variable starting with kak_opt_pluk_
            # Format: kak_opt_pluk_ui_face=info
            pluk_opts=$(set | grep "^kak_opt_pluk_")

            # Pass the block and the raw env list to Lua
            (lua -e "require('pluk').parse_setup([=[$1]=], [=[$pluk_opts]=], '$kak_session')" 2>> "$logfile") &
        }
    }
}
