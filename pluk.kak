# =============================================================================
# PUBLIC OPTIONS
# =============================================================================
declare-option -docstring "Plugin installation directory" \
    str pluk_install_dir %sh{ echo "${kak_config}/plugins" }

declare-option -docstring "Sets the log level for pluk: ERROR, INFO, DEBUG, and TRACE" \
    str pluk_loglevel "ERROR"

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
        plugin_dir="$kak_opt_pluk_install_dir"
        export LUA_PATH="$plugin_dir/?.lua;$plugin_dir/?/init.lua;;"

        # Add all pluk options to shell environment
        echo "
            $kak_opt_pluk_install_dir
            $kak_opt_pluk_loglevel
            $kak_opt_pluk_git_protocol
            $kak_opt_pluk_git_domain

            # Make sure client and session are known by lua
            $kak_client
            $kak_session
            $kak_config
        " >/dev/null

        # Runs setup based on constructed table of repos
        (lua -e "require('pluk').run_setup([=[$1]=])" >/dev/null 2>&1) &
    }
}

define-command pluk-repo -params 2..4 \
    -docstring "pluk-repo [flag] <url> <path> [config]" \
    -shell-script-candidates %{ echo "-no-source"; echo "-auto-source" } \
    %{ evaluate-commands %sh{
        case "$1" in -no-source|-auto-source) shift ;; esac
        url="$1"; path="$2"

        # Regex: Full Git URL (SSH, HTTPS, or Git protocols)
        git_url_regex="^((https?|git|ssh)://|git@).+$"
        # Regex: Valid Linux Path (allows alphanumeric, dots, underscores, dashes, slashes)
        linux_path_regex="^[a-zA-Z0-9._/-]+$"

        if ! echo "$url" | grep -Eq "$git_url_regex"; then
            echo "fail 'pluk-repo: invalid git URL ($url)'"
        elif ! echo "$path" | grep -Eq "$linux_path_regex"; then
            echo "fail 'pluk-repo: invalid linux path ($path)'"
        fi
    }}

define-command pluk -params 1..3 \
    -docstring "pluk [flag] <repo> [config]" \
    -shell-script-candidates %{ echo "-no-source"; echo "-auto-source" } \
    %{ evaluate-commands %sh{
        case "$1" in -no-source|-auto-source) shift ;; esac
        repo="$1"

        # Regex: URL Path (e.g., 'mawww/kakoune' or 'user/repo-name.kak')
        url_path_regex="^[a-zA-Z0-9._/-]+$"

        if ! echo "$repo" | grep -Eq "$url_path_regex"; then
            echo "fail 'pluk: invalid repo path ($repo)'"
        fi
    }}

define-command pluk-colorscheme -params 2..3 \
    -docstring "pluk-colorscheme <repo> <name> [config]" \
    %{ evaluate-commands %sh{
        repo="$1"; name="$2"

        url_path_regex="^[a-zA-Z0-9._/-]+$"
        # Regex: No forward slashes allowed in filenames
        filename_regex="^[^/.]+$"

        if ! echo "$repo" | grep -Eq "$url_path_regex"; then
            echo "fail 'pluk-colorscheme: invalid repo path ($repo)'"
        elif ! echo "$name" | grep -Eq "$filename_regex"; then
            echo "fail 'pluk-colorscheme: invalid filename ($name) - file name without ''.'''"
        fi
    }}

define-command pluk-install-hook -params 1 \
    -docstring "pluk-install-hook <command>" \
    %{ evaluate-commands %sh{
        cmd="$1"

        if [ -z "$cmd" ]; then
            echo "fail 'pluk-install-hook: empty command string'"
        fi
    }}

}
