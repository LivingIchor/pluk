# pluk

A straightforward plugin manager for Kakoune.

I built **pluk** because I wanted a manager that was easy to troubleshoot and didn't feel over-engineered. It handles the basics—downloading, sourcing, and configuring plugins—without getting in your way.

## Why this exists

There are great managers out there, but I found them a bit hard to customize when things went sideways. **pluk** is small enough that you can read the source code in one sitting and change how it works if you need to.

## Installation

You can bootstrap **pluk** by adding this to your `kakrc`:

```kak
evaluate-commands %sh{
    dest="${kak_config}/plugins/pluk/pluk.kak"
    if [ ! -f "$dest" ]; then
        mkdir -p "$(dirname "$dest")"
        curl -sL "https://raw.githubusercontent.com/your-user/pluk/master/pluk.kak" -o "$dest"
    fi
}
source "%val{config}/plugins/pluk/pluk.kak"
require-module pluk

```

## Basic Setup

Configure where plugins are stored and start adding them: 

```kak
set-option global pluk_install_dir "%val{config}/plugins"

pluk-setup %{
    # Just the repo
    pluk "mawww/kakoune-gdb"

    # With a config block
    pluk "andreyorst/fzf.kak" %{
        set-option global fzf_preview_width '50%'
        map global user f ': fzf-mode<ret>' -docstring 'fzf mode'
    }

    # With an installation hook
    pluk "kak-lsp/kak-lsp" %{
        pluk-install-hook %{
            cargo install --locked --force --path .
        }

        map global user l %{:enter-user-mode lsp<ret>} -docstring "LSP mode"
    }
}

```

## How it works

* **`pluk-setup`**: Wraps your plugin list. 


* **`pluk`**: Takes a GitHub handle (user/repo) and an optional config block. 


* **`pluk-install-hook`**: Runs shell commands inside the plugin's directory—useful for things like `cargo build` or `npm install`. 
