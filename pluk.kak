# =============================================================================
# PUBLIC OPTIONS
# =============================================================================
declare-option -docstring "Plugin installation directory" \
    str pluk_install_dir "$HOME/.local/share/kak/plugins"

declare-option -docstring "Git protocol used by the pluk command" \
    str pluk_git_protocol "https://"

declare-option -docstring "Git domain used by the pluk command" \
    str pluk_git_domain "github.com"

# =============================================================================
# INTERNAL STATE
# =============================================================================
declare-option -hidden str	_pluk_root_dir
declare-option -hidden bool	_pluk_settingup		false
declare-option -hidden str	_pluk_repo_table	"{}"
declare-option -hidden str	_pluk_current_dir	""
declare-option -hidden int	_pluk_config_index	0

# =============================================================================
# MODULE
# =============================================================================
provide-module pluk %{

# Initialize the path once when required
evaluate-commands %sh{
    dir=$(dirname "$kak_source")
    printf "set-option global _pluk_root_dir '%s'" "$dir"
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
    evaluate-commands %sh{
        protocol="$kak_opt_pluk_git_protocol"
        domain="$kak_opt_pluk_git_domain"

        arg1="${protocol}${domain}/$1"
        arg2="$1"
        arg3="$2"

        printf "pluk-repo '%s' '%s' %%{%s}" "$arg1" "$arg2" "$arg3"
    }
}

define-command pluk-repo -params 1..3 \
    -docstring "" \
%{
    set-option global _pluk_current_dir %arg{2}

    evaluate-commands %sh{
        # Do nothing if outside a setup block
        [ "$kak_opt__pluk_settingup" = "false" ] && exit

        # 1. Check if empty
        if [ -z "$2" ]; then
            type="empty"

        # 2. Check if it looks like a config block
        # Look for newlines or spaces which don't normally exist in a path
        elif echo "$2" | grep -qE "(set-option|map|require-module|pluk-install-hook)"; then
            type="config"

        # 3. Otherwise, it's a path
        else
            type="path"
        fi

        # Log the argument type
        echo "echo -debug 'Arg 2 type: $type'"

        # Example of how to shift variables if Arg 2 was actually a config
        if [ "$type" = "config" ]; then
            true_path=""
            true_config="$2"
        else
            true_path="$2"
            true_config="$3"
        fi

        # Make sure client and session are know by lua
        echo "
            $kak_client
            $kak_session
        " >/dev/null

        index=$kak_opt__pluk_config_index
        echo "set-option global _pluk_config_index $((index + 1))"

        updated_table=$(lua - <<EOF
            local repo_table = $kak_opt__pluk_repo_table
            require('pluk').add_repo(repo_table, [=[$1]=], [=[$true_path]=], [=[$true_config]=])
EOF
        )

        echo "set-option global _pluk_repo_table %{ $updated_table }"
    }

    set-option global _pluk_current_dir ""
}

define-command pluk-install-hook -params 1 \
    -docstring "" \
%{
    evaluate-commands %sh{
        [ "$kak_opt__pluk_current_dir" = "" ] && exit

        echo "
            hook global User pluk-install-index-$kak_opt__pluk_config_index %sh{
                cd ${kak_opt_pluk_install_dir}/${kak_opt__pluk_current_dir}

                $1
            }
        "
    }
}

}
