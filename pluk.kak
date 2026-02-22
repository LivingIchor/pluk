# =============================================================================
# PUBLIC OPTIONS
# =============================================================================
declare-option -docstring "Plugin installation directory" \
    str pluk_install_dir "$HOME/.local/share/kak/plugins"

# =============================================================================
# INTERNAL STATE
# =============================================================================
declare-option -hidden str	_pluk_dir
declare-option -hidden bool	_pluk_settingup		false
declare-option -hidden str	_pluk_repo_table	"{}"
declare-option -hidden str	_pluk_current		""
declare-option -hidden int	_pluk_config_index	0

# =============================================================================
# MODULE
# =============================================================================
provide-module pluk %{

# Initialize the path once when required
evaluate-commands %sh{
    dir=$(dirname "$kak_source")
    printf "set-option global _pluk_dir '%s'" "$dir"
}

define-command pluk-setup -params 1 \
    -docstring "" \
%{
    set-option global _pluk_settingup true
    eval %arg{1}

    set-option global _pluk_settingup false
    evaluate-commands %sh{
        # Set private options
        repo_table="$kak_opt__pluk_repo_table"

        # Add all pluk options to shell environment
        echo "
            $kak_opt_pluk_install_dir

            # Make sure client and session are know by lua
            $kak_client
            $kak_session
        " >/dev/null

        # Capture every environment variable starting with kak_opt_pluk_
        # Format: kak_opt_pluk_ui_face=info
        pluk_opts=$(set | grep "^kak_opt_pluk_")

        # Runs setup based on constructed table of repos
        (lua -e "
            local repo_table = $repo_table \
            require('pluk').run_setup(repo_table, [=[$pluk_opts]=])
        ") &
    }
}

define-command pluk -params 1..2 \
    -docstring "" \
%{
    set-option global _pluk_current %arg{1}

    evaluate-commands %sh{
        # Do nothing if outside a setup block
        [ "$kak_opt__pluk_settingup" = "false" ] && exit

        # Make sure client and session are know by lua
        echo "
            $kak_client
            $kak_session
        " >/dev/null

        index=$kak_opt__pluk_config_index
        echo "set-option global _pluk_config_index $((index + 1))"

        updated_table=$(lua - <<EOF
            local repo_table = $kak_opt__pluk_repo_table
            require('pluk').add_repo(repo_table, [=[$1]=], [=[$2]=])
EOF
        )

        echo "set-option global _pluk_repo_table %{ $updated_table }"
    }

    set-option global _pluk_current ""
}

define-command pluk-install-hook -params 1 \
    -docstring "" \
%{
    evaluate-commands %sh{
        [ "$kak_opt__pluk_current" = "" ] && exit

        echo "
            hook global User pluk-install-index-$kak_opt__pluk_config_index %sh{
                cd ${kak_opt_pluk_install_dir}/${kak_opt__pluk_current}

                $1
            }
        "
    }
}

}
