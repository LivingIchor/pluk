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

# =============================================================================
# MODULE
# =============================================================================
provide-module pluk %{

# Initialize the path once when required
eval %sh{
    dir=$(dirname "$kak_source")
    printf "set-option global _pluk_root_dir '%s'" "$dir"
}

def pluk-setup -params 1 \
    -docstring "" \
%{
    eval %sh{
        # Add all pluk options to shell environment
        echo "
            $kak_opt_pluk_install_dir
            $kak_opt_pluk_git_protocol
            $kak_opt_pluk_git_domain

            # Make sure client and session are known by lua
            $kak_client
            $kak_session
        " >/dev/null

        # Runs setup based on constructed table of repos
        (lua -e "require('pluk').run_setup([=[$1]=])") &
    }
}

def pluk -params 1..2 -docstring "" %{}

def pluk-repo -params 1..3 -docstring "" %{}

def pluk-install-hook -params 1 -docstring "" %{}

}
