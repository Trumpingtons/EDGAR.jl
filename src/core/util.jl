# Small cross-cutting helpers (jurisdiction-agnostic): hand a path/URL to the OS opener.

# Internal: hand a local file path (or URL) to the OS to open in its default
# application — the browser, for HTML. The single place the platform dispatch lives.
function _open_in_default_app(target::AbstractString)
    cmd = Sys.isapple()   ? `open $target` :
          Sys.iswindows() ? `cmd /c start "" $target` : `xdg-open $target`
    run(cmd)
    return target
end
