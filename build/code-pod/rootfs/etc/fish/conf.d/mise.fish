if status is-interactive
    if command -v mise > /dev/null
        mise activate fish | source
    end
end
