# shellcheck shell=sh
# kiro-profile.sh — Source this in .bashrc / .zshrc
#
#   source "${XDG_DATA_HOME:-$HOME/.local/share}/kiro-profile/kiro-profile.sh"
#
# Provides:
#   kiro-cli       — runs Kiro CLI with the active/default profile
#   kiro-profile   — manage profiles (create, list, delete, default, use, which, ...)
#
# Each profile is a directory under
#   ${XDG_DATA_HOME:-$HOME/.local/share}/kiro-profiles/<name>
# and "using" a profile simply exports _KIRO_HOME to point at it. Kiro stores
# all of its per-user state (auth/login, settings, agents, prompts, skills,
# steering, sessions) under _KIRO_HOME, defaulting to ~/.kiro. When no profile
# and no default are active, _KIRO_HOME is left unset so Kiro uses ~/.kiro
# exactly as a stock install would.
#
# Supports bash and zsh on Linux and macOS. The hyphenated `kiro-cli` /
# `kiro-profile` function names are not valid in strict POSIX sh (dash), so a
# pure-sh /bin/sh is not a supported sourcing shell.
# Windows / MSYS is intentionally not supported yet.

# --- Internal helpers ---

_kp_die() {
    printf 'kiro-profile: %s\n' "$1" >&2
}

# Resolves the profile data directory (plural "kiro-profiles"), honoring XDG.
_kp_data_dir() {
    _kp_dd_base="${XDG_DATA_HOME:-${HOME}/.local/share}"
    # A relative XDG_DATA_HOME would make every profile path relative, which
    # breaks the directory-local auto-switch resolution (it compares against an
    # absolute $PWD) and cp targets. Fall back to the default in that case.
    case "$_kp_dd_base" in
        /*) : ;;
        *)
            _kp_die "ignoring non-absolute XDG_DATA_HOME '${_kp_dd_base}'; using ~/.local/share"
            _kp_dd_base="${HOME}/.local/share"
            ;;
    esac
    printf '%s\n' "${_kp_dd_base}/kiro-profiles"
}

# Resolves the tool's own install directory (singular "kiro-profile"),
# distinct from the plural data directory. Honors XDG (absolute only).
_kp_install_dir() {
    _kp_id_base="${XDG_DATA_HOME:-${HOME}/.local/share}"
    case "$_kp_id_base" in
        /*) : ;;
        *) _kp_id_base="${HOME}/.local/share" ;;
    esac
    printf '%s\n' "${_kp_id_base}/kiro-profile"
}

# Creates a directory (and parents) with owner-only 0700 permissions, so
# profile trees holding auth/session secrets are never group/other-readable.
# Usage: _kp_mkdir_private <dir>
_kp_mkdir_private() {
    ( umask 077 && mkdir -p "$1" ) || {
        _kp_die "could not create directory '$1'"
        return 1
    }
    # mkdir -p won't tighten an already-existing dir; enforce 0700 on the leaf.
    chmod 700 "$1" 2>/dev/null || :
    return 0
}

_kp_validate_name() {
    case "$1" in
        "")
            _kp_die "profile name must not be empty"
            return 1
            ;;
        .*)
            _kp_die "invalid profile name '$1': must not start with '.'"
            return 1
            ;;
        *..*)
            _kp_die "invalid profile name '$1': must not contain '..'"
            return 1
            ;;
        */*)
            _kp_die "invalid profile name '$1': must not contain '/'"
            return 1
            ;;
        *\\*)
            _kp_die "invalid profile name '$1': must not contain '\\'"
            return 1
            ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_-]*)
            _kp_die "invalid profile name '$1': use only letters, digits, hyphens, underscores"
            return 1
            ;;
    esac
}

# Resolves the source directory to import from: an explicit path if given,
# else $_KIRO_HOME if set, else ~/.kiro. Sets _kp_import_src. Returns 1 with a
# diagnostic if the resolved source is not a readable directory.
_kp_resolve_import_src() {
    if [ -n "${1:-}" ]; then
        _kp_import_src="$1"
    elif [ -n "${_KIRO_HOME:-}" ]; then
        _kp_import_src="$_KIRO_HOME"
    else
        _kp_import_src="${HOME}/.kiro"
    fi
    if [ ! -d "$_kp_import_src" ]; then
        _kp_die "import source '${_kp_import_src}' is not a directory"
        return 1
    fi
    return 0
}

# Copies the full contents of directory $1 into the (already-created, empty)
# profile directory $2, preserving permissions and including dotfiles. Uses a
# trailing "/." on the source so the directory's contents — not the directory
# itself — land in the target. cp's own stderr is surfaced so a real cause
# (permissions, ENOSPC) isn't hidden behind a generic message.
_kp_copy_tree() {
    if ! cp -a "${1%/}/." "$2/"; then
        _kp_die "failed to copy '${1}' into '${2}'"
        return 1
    fi
    return 0
}

# Shared implementation behind `import` and `create --from`: validates the
# name, refuses an existing NON-EMPTY profile (an existing empty dir is
# reused, so `create work` followed by `import work` no longer dead-ends),
# resolves and sanity-checks the source, creates the profile dir 0700, and
# copies the tree in. On success sets _kp_dir. Usage:
#   _kp_make_profile_from <data_dir> <name> <from_or_empty> <from_set:0|1>
_kp_make_profile_from() {
    _kp_mpf_data="$1"
    _kp_mpf_name="$2"
    _kp_mpf_from="$3"
    _kp_mpf_from_set="$4"

    _kp_validate_name "$_kp_mpf_name" || return 1
    _kp_dir="${_kp_mpf_data}/${_kp_mpf_name}"
    if [ -d "$_kp_dir" ]; then
        # Reuse an existing empty dir; refuse a populated one.
        if [ -n "$(ls -A "$_kp_dir" 2>/dev/null)" ]; then
            _kp_die "profile '${_kp_mpf_name}' already exists"
            return 1
        fi
    fi

    if [ "$_kp_mpf_from_set" -eq 1 ]; then
        _kp_resolve_import_src "$_kp_mpf_from" || return 1
    else
        _kp_resolve_import_src "" || return 1
    fi
    # Guard against importing a profile into itself (_KIRO_HOME may already
    # point at a managed profile dir). Trailing slashes are covered by the glob.
    case "$_kp_import_src" in
        "${_kp_mpf_data}"/*)
            _kp_die "refusing to import from another managed profile directory: ${_kp_import_src}"
            return 1
            ;;
    esac

    _kp_mkdir_private "$_kp_dir" || return 1
    if ! _kp_copy_tree "$_kp_import_src" "$_kp_dir"; then
        # Only clean up a dir we just made empty; never rm a reused populated one.
        rmdir "$_kp_dir" 2>/dev/null || :
        return 1
    fi
    # cp -a copies the SOURCE directory's mode onto the destination, which can
    # loosen the 0700 we just set (e.g. importing a 0755 ~/.kiro). Re-assert
    # owner-only on the profile root so secrets are never world-readable.
    chmod 700 "$_kp_dir" 2>/dev/null || :
    printf 'Created profile: %s\n' "$_kp_mpf_name"
    printf '_KIRO_HOME directory: %s\n' "$_kp_dir"
    printf 'Imported from: %s\n' "$_kp_import_src"
    printf "Tip: run 'kiro-profile use %s' to activate it.\\n" "$_kp_mpf_name"
    return 0
}

# --- Version tracking helpers ---

# Reads the installed VERSION file; prints "unknown" if missing/empty.
_kp_installed_version() {
    _kp_ver_file="$(_kp_install_dir)/VERSION"
    if [ -f "$_kp_ver_file" ]; then
        _kp_ver=$(cat "$_kp_ver_file")
        if [ -n "$_kp_ver" ]; then
            printf '%s\n' "$_kp_ver"
            return 0
        fi
    fi
    printf 'unknown\n'
}

# Numeric MAJOR.MINOR.PATCH comparison. Usage: _kp_version_lt A B
# Returns 0 (true, shell success) if A < B, 1 (false) otherwise.
# "unknown" is always less than any real version, and equal to itself.
_kp_version_lt() {
    _kp_vlt_a="$1"
    _kp_vlt_b="$2"
    if [ "$_kp_vlt_a" = "unknown" ]; then
        [ "$_kp_vlt_b" = "unknown" ] && return 1
        return 0
    fi
    [ "$_kp_vlt_b" = "unknown" ] && return 1
    _kp_vlt_a1=$(printf '%s' "$_kp_vlt_a" | cut -d. -f1)
    _kp_vlt_a2=$(printf '%s' "$_kp_vlt_a" | cut -d. -f2)
    _kp_vlt_a3=$(printf '%s' "$_kp_vlt_a" | cut -d. -f3)
    _kp_vlt_b1=$(printf '%s' "$_kp_vlt_b" | cut -d. -f1)
    _kp_vlt_b2=$(printf '%s' "$_kp_vlt_b" | cut -d. -f2)
    _kp_vlt_b3=$(printf '%s' "$_kp_vlt_b" | cut -d. -f3)
    _kp_vlt_a1=${_kp_vlt_a1:-0}; _kp_vlt_a2=${_kp_vlt_a2:-0}; _kp_vlt_a3=${_kp_vlt_a3:-0}
    _kp_vlt_b1=${_kp_vlt_b1:-0}; _kp_vlt_b2=${_kp_vlt_b2:-0}; _kp_vlt_b3=${_kp_vlt_b3:-0}
    case "$_kp_vlt_a1" in ''|*[!0-9]*) _kp_vlt_a1=0 ;; esac
    case "$_kp_vlt_a2" in ''|*[!0-9]*) _kp_vlt_a2=0 ;; esac
    case "$_kp_vlt_a3" in ''|*[!0-9]*) _kp_vlt_a3=0 ;; esac
    case "$_kp_vlt_b1" in ''|*[!0-9]*) _kp_vlt_b1=0 ;; esac
    case "$_kp_vlt_b2" in ''|*[!0-9]*) _kp_vlt_b2=0 ;; esac
    case "$_kp_vlt_b3" in ''|*[!0-9]*) _kp_vlt_b3=0 ;; esac
    [ "$_kp_vlt_a1" -lt "$_kp_vlt_b1" ] && return 0
    [ "$_kp_vlt_a1" -gt "$_kp_vlt_b1" ] && return 1
    [ "$_kp_vlt_a2" -lt "$_kp_vlt_b2" ] && return 0
    [ "$_kp_vlt_a2" -gt "$_kp_vlt_b2" ] && return 1
    [ "$_kp_vlt_a3" -lt "$_kp_vlt_b3" ] && return 0
    return 1
}

# --- Passive update check ---

_KP_REPO_API="${KIRO_PROFILE_UPDATE_API_BASE:-https://api.github.com/repos/quinnjr/kiro-profiles}"
_KP_ASSET_BASE="${KIRO_PROFILE_UPDATE_ASSET_BASE:-https://github.com/quinnjr/kiro-profiles/releases/download}"
_KP_UPDATE_INTERVAL="${KIRO_PROFILE_UPDATE_CHECK_INTERVAL:-86400}"
case "$_KP_UPDATE_INTERVAL" in ''|*[!0-9]*) _KP_UPDATE_INTERVAL=86400 ;; esac

# Extracts and validates a "vX.Y.Z" tag_name from a GitHub releases-API JSON
# body. Prints the version WITHOUT the leading 'v' on success; prints nothing
# on failure (missing field or not X.Y.Z).
_kp_extract_tag_version() {
    _kp_etv_tag=$(printf '%s' "$1" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)
    _kp_etv_tag=${_kp_etv_tag#v}
    case "$_kp_etv_tag" in
        [0-9]*.[0-9]*.[0-9]*)
            case "$_kp_etv_tag" in
                *[!0-9.]*) return 1 ;;
            esac
            printf '%s\n' "$_kp_etv_tag"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Verifies a downloaded file's SHA-256 against a SHA256SUMS file. Usage:
# _kp_verify_checksum <file> <sums-file>. Requires $_kp_sha_cmd to be set by
# the caller (sha256sum or "shasum -a 256").
_kp_verify_checksum() {
    _kp_vc_file="$1"
    _kp_vc_sums="$2"
    _kp_vc_name=$(basename "$_kp_vc_file")
    _kp_vc_expected=$(grep -F " ${_kp_vc_name}" "$_kp_vc_sums" 2>/dev/null | awk '{print $1}' | head -n1)
    [ -n "$_kp_vc_expected" ] || return 1
    _kp_vc_actual=$($_kp_sha_cmd "$_kp_vc_file" | awk '{print $1}')
    [ "$_kp_vc_expected" = "$_kp_vc_actual" ]
}

# Fetches, checksum-verifies, and atomically replaces kiro-profile.sh (and the
# shared VERSION file) from the latest GitHub release. Returns 0 on success, 1
# on any failure — never leaves a partial install in place.
#
# NOTE: deliberately does NOT use `trap ... EXIT` for temp-dir cleanup. This
# file is sourced into a long-lived interactive shell, so a trap set here would
# persist for the rest of the session and fire at the wrong time. Cleanup is
# explicit at every return point instead.
_kp_do_update() {
    _kp_upd_force=0
    case "${1:-}" in
        --force) _kp_upd_force=1 ;;
        "") : ;;
        *) _kp_die "usage: kiro-profile update [--force]"; return 1 ;;
    esac

    command -v curl >/dev/null 2>&1 || { _kp_die "update requires curl"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        _kp_sha_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        _kp_sha_cmd="shasum -a 256"
    else
        _kp_die "update requires sha256sum or shasum"
        return 1
    fi

    _kp_upd_resp=$(curl -fsSL --connect-timeout 10 --max-time 30 "${_KP_REPO_API}/releases/latest" 2>/dev/null) || {
        _kp_die "update failed: could not reach GitHub"
        return 1
    }
    _kp_upd_latest=$(_kp_extract_tag_version "$_kp_upd_resp")
    if [ -z "$_kp_upd_latest" ]; then
        _kp_die "update failed: could not determine latest version"
        return 1
    fi
    _kp_upd_tag="v${_kp_upd_latest}"

    _kp_upd_installed=$(_kp_installed_version)
    if [ "$_kp_upd_force" -eq 0 ] && [ "$_kp_upd_installed" != "unknown" ] \
        && ! _kp_version_lt "$_kp_upd_installed" "$_kp_upd_latest"; then
        _kp_die "already up to date (v${_kp_upd_installed}); latest is v${_kp_upd_latest}"
        return 1
    fi

    _kp_upd_install="$(_kp_install_dir)"
    mkdir -p "$_kp_upd_install" || { _kp_die "update failed: could not create install directory"; return 1; }
    _kp_upd_tmpdir=$(mktemp -d "${_kp_upd_install}/.update.XXXXXX") || { _kp_die "update failed: could not create temp directory"; return 1; }
    _kp_upd_base="${_KP_ASSET_BASE}/${_kp_upd_tag}"

    if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "${_kp_upd_tmpdir}/SHA256SUMS" "${_kp_upd_base}/SHA256SUMS" 2>/dev/null; then
        _kp_die "update failed: could not download checksums"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "${_kp_upd_tmpdir}/VERSION" "${_kp_upd_base}/VERSION" 2>/dev/null; then
        _kp_die "update failed: could not download VERSION"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "${_kp_upd_tmpdir}/kiro-profile.sh" "${_kp_upd_base}/kiro-profile.sh" 2>/dev/null; then
        _kp_die "update failed: could not download kiro-profile.sh"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi

    # TRUST MODEL: SHA256SUMS is fetched from the same GitHub release as the
    # artifacts it checksums, so this verifies transfer INTEGRITY (a truncated
    # or corrupted download is caught) but NOT AUTHENTICITY beyond whatever
    # trust you place in GitHub + TLS. Anyone able to publish a release to
    # quinnjr/kiro-profiles controls both files. This updater overwrites the
    # very script you source into every shell, so treat it as an
    # RCE-equivalent trust boundary. If stronger guarantees are ever needed,
    # add detached signatures (minisign/cosign) verified against a public key
    # pinned in this script — do not mistake the checksum below for that.
    if ! _kp_verify_checksum "${_kp_upd_tmpdir}/VERSION" "${_kp_upd_tmpdir}/SHA256SUMS"; then
        _kp_die "update failed: VERSION checksum mismatch"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi
    if ! _kp_verify_checksum "${_kp_upd_tmpdir}/kiro-profile.sh" "${_kp_upd_tmpdir}/SHA256SUMS"; then
        _kp_die "update failed: kiro-profile.sh checksum mismatch"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi

    _kp_upd_downloaded_version=$(cat "${_kp_upd_tmpdir}/VERSION")
    if [ "$_kp_upd_downloaded_version" != "$_kp_upd_latest" ]; then
        _kp_die "update failed: downloaded VERSION (${_kp_upd_downloaded_version}) does not match release tag (${_kp_upd_latest})"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi

    if ! mv -f "${_kp_upd_tmpdir}/kiro-profile.sh" "${_kp_upd_install}/kiro-profile.sh"; then
        _kp_die "update failed: could not replace kiro-profile.sh"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi
    if ! mv -f "${_kp_upd_tmpdir}/VERSION" "${_kp_upd_install}/VERSION"; then
        _kp_die "update failed: could not replace VERSION"
        rm -rf "$_kp_upd_tmpdir"
        return 1
    fi
    rm -rf "$_kp_upd_tmpdir"

    case "$_kp_upd_installed" in
        unknown) _kp_upd_installed_display="unknown" ;;
        *) _kp_upd_installed_display="v${_kp_upd_installed}" ;;
    esac
    printf 'Updating kiro-profile.sh: %s -> v%s\n' "$_kp_upd_installed_display" "$_kp_upd_latest"
    printf "Done. Run 'source ~/.bashrc' (or restart your shell) to use the new version.\\n"
    return 0
}

# Reads the update-check cache into _kp_cache_ts / _kp_cache_ver /
# _kp_cache_notified. Defaults (0 / unknown / 0) on missing or unparseable
# cache, so a corrupted file self-heals on the next successful write.
_kp_read_update_cache() {
    _kp_cache_ts=0
    _kp_cache_ver="unknown"
    _kp_cache_notified=0
    _kp_cache_file="$(_kp_install_dir)/.update-check"
    [ -f "$_kp_cache_file" ] || return 0
    _kp_line_n=0
    while IFS= read -r _kp_field; do
        _kp_line_n=$((_kp_line_n + 1))
        case "$_kp_line_n" in
            1) case "$_kp_field" in *[!0-9]*|'') ;; *) _kp_cache_ts="$_kp_field" ;; esac ;;
            2) [ -n "$_kp_field" ] && _kp_cache_ver="$_kp_field" ;;
            3) case "$_kp_field" in 0|1) _kp_cache_notified="$_kp_field" ;; esac ;;
        esac
        [ "$_kp_line_n" -ge 3 ] && break
    done < "$_kp_cache_file"
    return 0
}

# Rate-limited stderr diagnostic for persistent local cache-file I/O failures
# (permissions, disk full) — distinct from transient network failures, which
# stay silent by design. Best-effort: uses a separate marker file so a broken
# .update-check write doesn't also block this diagnostic.
_kp_warn_cache_write_failure() {
    _kp_wcf_dir="$1"
    _kp_wcf_now="$2"
    _kp_wcf_marker="${_kp_wcf_dir}/.update-check-diag"
    _kp_wcf_last=0
    if [ -f "$_kp_wcf_marker" ]; then
        _kp_wcf_read=$(cat "$_kp_wcf_marker" 2>/dev/null)
        case "$_kp_wcf_read" in ''|*[!0-9]*) ;; *) _kp_wcf_last="$_kp_wcf_read" ;; esac
    fi
    if [ $((_kp_wcf_now - _kp_wcf_last)) -ge "$_KP_UPDATE_INTERVAL" ]; then
        printf 'kiro-profile: warning: could not write update-check cache in %s -- update notifications may not work until this is fixed\n' "$_kp_wcf_dir" >&2
        printf '%s\n' "$_kp_wcf_now" > "$_kp_wcf_marker" 2>/dev/null || :
    fi
    return 0
}

# Writes the cache atomically (temp file + rename), so concurrent invocations
# can't torn-write it. Usage: _kp_write_update_cache TS VER NOTIFIED
_kp_write_update_cache() {
    _kp_wuc_dir="$(_kp_install_dir)"
    mkdir -p "$_kp_wuc_dir" 2>/dev/null || { _kp_warn_cache_write_failure "$_kp_wuc_dir" "$1"; return 1; }
    _kp_wuc_file="${_kp_wuc_dir}/.update-check"
    _kp_wuc_tmp="${_kp_wuc_file}.tmp.$$"
    if ! printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$_kp_wuc_tmp" 2>/dev/null; then
        rm -f "$_kp_wuc_tmp" 2>/dev/null
        _kp_warn_cache_write_failure "$_kp_wuc_dir" "$1"
        return 1
    fi
    mv -f "$_kp_wuc_tmp" "$_kp_wuc_file" 2>/dev/null || {
        rm -f "$_kp_wuc_tmp" 2>/dev/null
        _kp_warn_cache_write_failure "$_kp_wuc_dir" "$1"
        return 1
    }
    return 0
}

# Runs the passive update check, rate-limited to once per
# KIRO_PROFILE_UPDATE_CHECK_INTERVAL seconds (default 24h). Prints a one-line
# stderr notice the first time a newer version is seen. Every failure path is a
# silent no-op — this must never block or break kiro-cli().
_kp_update_check() {
    [ -n "${KIRO_PROFILE_NO_UPDATE_CHECK:-}" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0

    _kp_read_update_cache

    _kp_now=$(date +%s 2>/dev/null) || return 0
    case "$_kp_now" in ''|*[!0-9]*) return 0 ;; esac
    _kp_elapsed=$((_kp_now - _kp_cache_ts))

    if [ "$_kp_elapsed" -ge "$_KP_UPDATE_INTERVAL" ]; then
        _kp_resp=$(curl -fsSL --connect-timeout 3 --max-time 3 "${_KP_REPO_API}/releases/latest" 2>/dev/null)
        _kp_new_ver="$_kp_cache_ver"
        if [ -n "$_kp_resp" ]; then
            _kp_extracted=$(_kp_extract_tag_version "$_kp_resp")
            [ -n "$_kp_extracted" ] && _kp_new_ver="$_kp_extracted"
        fi
        if [ "$_kp_new_ver" != "$_kp_cache_ver" ]; then
            _kp_write_update_cache "$_kp_now" "$_kp_new_ver" 0
            _kp_cache_ver="$_kp_new_ver"
            _kp_cache_notified=0
        else
            _kp_write_update_cache "$_kp_now" "$_kp_cache_ver" "$_kp_cache_notified"
        fi
    fi

    if [ "$_kp_cache_notified" = "0" ] && [ "$_kp_cache_ver" != "unknown" ]; then
        _kp_installed=$(_kp_installed_version)
        if _kp_version_lt "$_kp_installed" "$_kp_cache_ver"; then
            case "$_kp_installed" in
                unknown) _kp_installed_display="unknown" ;;
                *) _kp_installed_display="v${_kp_installed}" ;;
            esac
            printf "A new kiro-profile version is available (%s -> v%s). Run 'kiro-profile update' to upgrade.\\n" \
                "$_kp_installed_display" "$_kp_cache_ver" >&2
            _kp_write_update_cache "$_kp_now" "$_kp_cache_ver" 1
        fi
    fi
    return 0
}

# --- Directory-local profile (.kiro-profile) auto-switching ---
#
# A directory may contain a `.kiro-profile` file whose first non-empty,
# non-comment line names a profile. Entering that directory (or any descendant)
# switches _KIRO_HOME to it; leaving reverts to the default. An explicit
# `kiro-profile use <name>` pins the session and suppresses auto-switching
# until `kiro-profile auto on`.
#
# Environment knobs:
#   KIRO_PROFILE_NO_AUTO_SWITCH=1   disable auto-switching entirely
#   KIRO_PROFILE_AUTO_QUIET=1       switch silently (no stderr notices)
#
# KIRO_PROFILE_AUTO_SET is exported so nested shells know the current _KIRO_HOME
# came from auto-switching (and may be re-managed) rather than an explicit use.

_KP_DOTFILE=".kiro-profile"
_KP_CR=$(printf '\r')

_kp_auto_notice() {
    [ -n "${KIRO_PROFILE_AUTO_QUIET:-}" ] && return 0
    printf 'kiro-profile: %s\n' "$1" >&2
    return 0
}

# Sets _kp_dotfile to the nearest .kiro-profile at or above directory $1, or
# empty when none is found. Uses only parameter expansion (no dirname/basename
# subprocesses): this runs on every shell prompt under bash's PROMPT_COMMAND,
# so a fork per path component would be felt.
_kp_find_dotfile() {
    _kp_dotfile=""
    _kp_fd_dir="$1"
    while :; do
        [ -n "$_kp_fd_dir" ] || _kp_fd_dir="/"
        if [ -f "${_kp_fd_dir%/}/${_KP_DOTFILE}" ]; then
            _kp_dotfile="${_kp_fd_dir%/}/${_KP_DOTFILE}"
            return 0
        fi
        [ "$_kp_fd_dir" = "/" ] && break
        _kp_fd_dir="${_kp_fd_dir%/*}"
    done
    return 1
}

# Sets _kp_dotname to the first non-empty, non-comment line of file $1, with
# surrounding whitespace and any trailing CR stripped.
_kp_read_dotfile() {
    _kp_dotname=""
    while IFS= read -r _kp_rd_line || [ -n "$_kp_rd_line" ]; do
        _kp_rd_line="${_kp_rd_line%"$_KP_CR"}"
        while :; do
            case "$_kp_rd_line" in
                " "*|"	"*) _kp_rd_line="${_kp_rd_line#?}" ;;
                *" "|*"	") _kp_rd_line="${_kp_rd_line%?}" ;;
                *) break ;;
            esac
        done
        case "$_kp_rd_line" in
            ''|'#'*) continue ;;
        esac
        _kp_dotname="$_kp_rd_line"
        return 0
    done < "$1"
    return 1
}

# Resolves and applies the directory-local profile for $PWD. Safe to call
# repeatedly: short-circuits when the directory hasn't changed, which also
# rate-limits the warnings below to once per directory entry.
_kp_auto_switch() {
    [ -n "${KIRO_PROFILE_NO_AUTO_SWITCH:-}" ] && return 0
    [ "${_KP_AUTO_OFF:-0}" = "1" ] && return 0
    [ "${PWD:-}" = "${_KP_AUTO_LAST_PWD:-}" ] && return 0
    _KP_AUTO_LAST_PWD="${PWD:-}"

    # An explicitly-chosen profile (kiro-profile use, or a _KIRO_HOME inherited
    # from outside) wins over any .kiro-profile file.
    if [ -n "${_KIRO_HOME:-}" ] && [ "$_KIRO_HOME" != "${KIRO_PROFILE_AUTO_SET:-}" ]; then
        return 0
    fi

    _kp_dotname=""
    if _kp_find_dotfile "${PWD:-}"; then
        _kp_read_dotfile "$_kp_dotfile"
    fi

    if [ -z "$_kp_dotname" ]; then
        if [ -n "${KIRO_PROFILE_AUTO_SET:-}" ]; then
            unset _KIRO_HOME
            unset KIRO_PROFILE_AUTO_SET
            _kp_auto_notice "directory profile cleared; using the default profile"
        fi
        [ -n "$_kp_dotfile" ] && _kp_die "ignoring ${_kp_dotfile}: no profile name in file"
        return 0
    fi

    case "$_kp_dotname" in
        .*|*..*|*/*|*\\*|*[!A-Za-z0-9_-]*)
            _kp_die "ignoring ${_kp_dotfile}: invalid profile name '${_kp_dotname}'"
            return 1
            ;;
    esac

    [ -n "${_KP_DATA_CACHE:-}" ] || _KP_DATA_CACHE=$(_kp_data_dir)
    _kp_as_dir="${_KP_DATA_CACHE}/${_kp_dotname}"
    if [ ! -d "$_kp_as_dir" ]; then
        _kp_die "ignoring ${_kp_dotfile}: profile '${_kp_dotname}' does not exist"
        return 1
    fi

    if [ "${_KIRO_HOME:-}" = "$_kp_as_dir" ]; then
        export KIRO_PROFILE_AUTO_SET="$_kp_as_dir"
        return 0
    fi
    export _KIRO_HOME="$_kp_as_dir"
    export KIRO_PROFILE_AUTO_SET="$_kp_as_dir"
    _kp_auto_notice "switched to profile '${_kp_dotname}' (from ${_kp_dotfile})"
    return 0
}

# Registers _kp_auto_switch with whatever directory-change mechanism the
# running shell offers. zsh has a real chpwd hook; bash only has
# PROMPT_COMMAND; everything else (dash, ash, ksh) gets a cd wrapper, which
# covers the common case even though it misses pushd/popd.
if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd _kp_auto_switch
elif [ -n "${BASH_VERSION:-}" ]; then
    case "${PROMPT_COMMAND:-}" in
        *_kp_auto_switch*) : ;;
        '') PROMPT_COMMAND="_kp_auto_switch" ;;
        *) PROMPT_COMMAND="${PROMPT_COMMAND%;};_kp_auto_switch" ;;
    esac
else
    # `command cd` bypasses this function, so re-sourcing can't recurse. eval
    # keeps the definition out of zsh's parser, which would otherwise
    # alias-expand `cd` at source time and abort with a parse error.
    eval 'cd() {
        command cd "$@" || return $?
        _kp_auto_switch
    }'
fi

# Resolve once at source time so a shell started inside a .kiro-profile tree is
# already on the right profile.
_kp_auto_switch

# --- kiro-cli() wrapper ---
# Auto-resolves the default profile before calling the real kiro-cli binary.
# If _KIRO_HOME is already set (e.g. via 'kiro-profile use'), it passes through
# without overriding. If nothing resolves, _KIRO_HOME is left unset so Kiro uses
# its own default (~/.kiro).

# shellcheck disable=SC3033  # hyphenated function name works in bash/zsh
kiro-cli() {
    _kp_update_check
    # Covers shells whose cd we couldn't hook (and directory changes made by
    # something other than cd) — resolving here is cheap and idempotent.
    _kp_auto_switch
    if [ -z "${_KIRO_HOME:-}" ]; then
        _kp_data=$(_kp_data_dir)
        _kp_def="${_kp_data}/.default"
        if [ -f "$_kp_def" ]; then
            _kp_name=$(cat "$_kp_def")
            if [ -n "$_kp_name" ] && [ -d "${_kp_data}/${_kp_name}" ]; then
                export _KIRO_HOME="${_kp_data}/${_kp_name}"
                # Mark it auto-managed, not an explicit pin: without this, the
                # first `kiro-cli` run would freeze the session on the default
                # profile and later .kiro-profile directories would be ignored.
                export KIRO_PROFILE_AUTO_SET="$_KIRO_HOME"
            fi
        fi
    fi
    command kiro-cli "$@"
}

# --- kiro-profile() management function ---

# shellcheck disable=SC3033  # hyphenated function name works in bash/zsh
kiro-profile() {
    _kp_data=$(_kp_data_dir)
    _kp_default_file="${_kp_data}/.default"

    case "${1:-}" in
        use)
            shift
            if [ -z "${1:-}" ]; then
                _kp_die "usage: kiro-profile use <name>"
                return 1
            fi
            _kp_name="$1"
            shift
            if [ -n "${1:-}" ]; then
                _kp_die "unexpected argument after profile name: '$1'"
                return 1
            fi
            _kp_validate_name "$_kp_name" || return 1
            _kp_dir="${_kp_data}/${_kp_name}"
            if [ ! -d "$_kp_dir" ]; then
                _kp_die "profile '${_kp_name}' does not exist. Create it with: kiro-profile create ${_kp_name}"
                return 1
            fi
            export _KIRO_HOME="$_kp_dir"
            # Dropping the auto-set marker pins the session: subsequent
            # directory changes will no longer override this choice.
            unset KIRO_PROFILE_AUTO_SET
            printf 'Switched to profile: %s\n' "$_kp_name"
            ;;

        auto)
            shift
            case "${1:-}" in
                on)
                    unset _KP_AUTO_OFF
                    unset _KIRO_HOME
                    unset KIRO_PROFILE_AUTO_SET
                    _KP_AUTO_LAST_PWD=""
                    _kp_auto_switch
                    printf 'Directory-local auto-switching enabled.\n'
                    ;;
                off)
                    _KP_AUTO_OFF=1
                    printf 'Directory-local auto-switching disabled for this session.\n'
                    ;;
                ""|status)
                    if [ -n "${KIRO_PROFILE_NO_AUTO_SWITCH:-}" ]; then
                        printf 'Auto-switching: disabled (KIRO_PROFILE_NO_AUTO_SWITCH is set)\n'
                    elif [ "${_KP_AUTO_OFF:-0}" = "1" ]; then
                        printf 'Auto-switching: disabled for this session\n'
                    elif [ -n "${_KIRO_HOME:-}" ] && [ "$_KIRO_HOME" != "${KIRO_PROFILE_AUTO_SET:-}" ]; then
                        printf 'Auto-switching: pinned (an explicit profile is active)\n'
                        printf "Run 'kiro-profile auto on' to resume auto-switching.\\n"
                    else
                        printf 'Auto-switching: enabled\n'
                    fi
                    if _kp_find_dotfile "${PWD:-}"; then
                        _kp_read_dotfile "$_kp_dotfile"
                        printf 'Directory profile: %s (%s)\n' "${_kp_dotname:-<empty>}" "$_kp_dotfile"
                    else
                        printf 'Directory profile: none in scope\n'
                    fi
                    ;;
                *)
                    _kp_die "usage: kiro-profile auto [on|off|status]"
                    return 1
                    ;;
            esac
            ;;

        local)
            shift
            case "${1:-}" in
                "")
                    if _kp_find_dotfile "${PWD:-}"; then
                        _kp_read_dotfile "$_kp_dotfile"
                        printf '%s\n' "$_kp_dotfile"
                        printf 'Profile: %s\n' "${_kp_dotname:-<empty>}"
                    else
                        _kp_die "no ${_KP_DOTFILE} found in this directory or any parent"
                        return 1
                    fi
                    ;;
                --remove|--clear)
                    if [ ! -f "./${_KP_DOTFILE}" ]; then
                        _kp_die "no ${_KP_DOTFILE} in the current directory"
                        return 1
                    fi
                    rm -f "./${_KP_DOTFILE}" || return 1
                    printf 'Removed %s\n' "${PWD}/${_KP_DOTFILE}"
                    _KP_AUTO_LAST_PWD=""
                    _kp_auto_switch
                    ;;
                -*)
                    _kp_die "unknown option '$1'"
                    return 1
                    ;;
                *)
                    _kp_name="$1"
                    shift
                    if [ -n "${1:-}" ]; then
                        _kp_die "unexpected argument after profile name: '$1'"
                        return 1
                    fi
                    _kp_validate_name "$_kp_name" || return 1
                    _kp_dir="${_kp_data}/${_kp_name}"
                    if [ ! -d "$_kp_dir" ]; then
                        _kp_die "profile '${_kp_name}' does not exist. Create it with: kiro-profile create ${_kp_name}"
                        return 1
                    fi
                    printf '%s\n' "$_kp_name" > "./${_KP_DOTFILE}" || return 1
                    printf 'Wrote %s (profile: %s)\n' "${PWD}/${_KP_DOTFILE}" "$_kp_name"
                    _KP_AUTO_LAST_PWD=""
                    _kp_auto_switch
                    ;;
            esac
            ;;

        create)
            shift
            _kp_do_init=0
            _kp_from=""
            _kp_from_set=0
            _kp_name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --init) _kp_do_init=1 ;;
                    --from)
                        shift
                        if [ -z "${1:-}" ]; then
                            _kp_die "--from requires a directory argument"
                            return 1
                        fi
                        _kp_from="$1"
                        _kp_from_set=1
                        ;;
                    --from=*)
                        _kp_from="${1#--from=}"
                        _kp_from_set=1
                        ;;
                    -*)
                        _kp_die "unknown option '$1'"
                        return 1
                        ;;
                    *)
                        if [ -n "$_kp_name" ]; then
                            _kp_die "unexpected argument '$1'"
                            return 1
                        fi
                        _kp_name="$1"
                        ;;
                esac
                shift
            done
            if [ -z "$_kp_name" ]; then
                _kp_die "usage: kiro-profile create [--init] [--from <dir>] <name>"
                return 1
            fi
            if [ "$_kp_do_init" -eq 1 ] && [ "$_kp_from_set" -eq 1 ]; then
                _kp_die "--init and --from are mutually exclusive"
                return 1
            fi
            if [ "$_kp_from_set" -eq 1 ]; then
                _kp_make_profile_from "$_kp_data" "$_kp_name" "$_kp_from" 1 || return 1
                return 0
            fi
            _kp_validate_name "$_kp_name" || return 1
            _kp_dir="${_kp_data}/${_kp_name}"
            if [ -d "$_kp_dir" ] && [ -n "$(ls -A "$_kp_dir" 2>/dev/null)" ]; then
                _kp_die "profile '${_kp_name}' already exists"
                return 1
            fi
            _kp_mkdir_private "$_kp_dir" || return 1
            printf 'Created profile: %s\n' "$_kp_name"
            printf '_KIRO_HOME directory: %s\n' "$_kp_dir"
            if [ "$_kp_do_init" -eq 1 ]; then
                mkdir -p "${_kp_dir}/settings"
                _kp_settings="${_kp_dir}/settings/cli.json"
                cat > "$_kp_settings" <<'SETTINGSEOF'
{
  "$schema": "https://kiro.dev/schemas/cli-settings.json",
  "note": "kiro-profile skeleton — edit or delete keys as needed. Auth/login state is stored under this _KIRO_HOME once you run 'kiro-cli login' with this profile active."
}
SETTINGSEOF
                printf 'Settings skeleton written to: %s\n' "$_kp_settings"
                printf "Tip: run 'kiro-profile use %s' then 'kiro-cli login' to authenticate this profile.\\n" "$_kp_name"
                if [ -n "${VISUAL:-}" ]; then
                    "${VISUAL}" "$_kp_settings"
                elif [ -n "${EDITOR:-}" ]; then
                    "${EDITOR}" "$_kp_settings"
                fi
            fi
            ;;

        import)
            shift
            _kp_from=""
            _kp_from_set=0
            _kp_name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --from)
                        shift
                        if [ -z "${1:-}" ]; then
                            _kp_die "--from requires a directory argument"
                            return 1
                        fi
                        _kp_from="$1"
                        _kp_from_set=1
                        ;;
                    --from=*)
                        _kp_from="${1#--from=}"
                        _kp_from_set=1
                        ;;
                    -*)
                        _kp_die "unknown option '$1'"
                        return 1
                        ;;
                    *)
                        if [ -n "$_kp_name" ]; then
                            _kp_die "unexpected argument '$1'"
                            return 1
                        fi
                        _kp_name="$1"
                        ;;
                esac
                shift
            done
            if [ -z "$_kp_name" ]; then
                _kp_die "usage: kiro-profile import [--from <dir>] <name>  (defaults to \$_KIRO_HOME or ~/.kiro)"
                return 1
            fi
            _kp_make_profile_from "$_kp_data" "$_kp_name" "$_kp_from" "$_kp_from_set" || return 1
            ;;

        list|ls)
            if [ ! -d "$_kp_data" ]; then
                printf 'No profiles found. Create one with: kiro-profile create <name>\n'
                return 0
            fi
            _kp_cur_default=""
            if [ -f "$_kp_default_file" ]; then
                _kp_cur_default=$(cat "$_kp_default_file")
            fi
            # Derive active profile name from _KIRO_HOME
            _kp_active=""
            if [ -n "${_KIRO_HOME:-}" ]; then
                case "${_KIRO_HOME%/}" in
                    "${_kp_data}"/*)
                        _kp_active=$(basename "${_KIRO_HOME%/}")
                        ;;
                esac
            fi
            _kp_found=0
            for _kp_entry in "$_kp_data"/*/; do
                [ -d "$_kp_entry" ] || continue
                _kp_entry_name=$(basename "$_kp_entry")
                _kp_found=1
                _kp_is_default=0
                _kp_is_active=0
                if [ "$_kp_entry_name" = "$_kp_cur_default" ]; then
                    _kp_is_default=1
                fi
                if [ "$_kp_entry_name" = "$_kp_active" ]; then
                    _kp_is_active=1
                fi
                if [ "$_kp_is_default" -eq 1 ] && [ "$_kp_is_active" -eq 1 ]; then
                    printf '>* %s (default, active)\n' "$_kp_entry_name"
                elif [ "$_kp_is_default" -eq 1 ]; then
                    printf ' * %s (default)\n' "$_kp_entry_name"
                elif [ "$_kp_is_active" -eq 1 ]; then
                    printf '>  %s (active)\n' "$_kp_entry_name"
                else
                    printf '   %s\n' "$_kp_entry_name"
                fi
            done
            if [ "$_kp_found" -eq 0 ]; then
                printf 'No profiles found. Create one with: kiro-profile create <name>\n'
            fi
            ;;

        default)
            shift
            if [ -z "${1:-}" ]; then
                if [ -f "$_kp_default_file" ]; then
                    _kp_name=$(cat "$_kp_default_file")
                    if [ -n "$_kp_name" ]; then
                        printf '%s\n' "$_kp_name"
                    else
                        _kp_die "default profile file is empty. Set one with: kiro-profile default <name>"
                        return 1
                    fi
                else
                    _kp_die "no default profile set. Set one with: kiro-profile default <name>"
                    return 1
                fi
                return 0
            fi
            _kp_name="$1"
            _kp_validate_name "$_kp_name" || return 1
            _kp_dir="${_kp_data}/${_kp_name}"
            if [ ! -d "$_kp_dir" ]; then
                _kp_die "profile '${_kp_name}' does not exist. Create it with: kiro-profile create ${_kp_name}"
                return 1
            fi
            _kp_mkdir_private "$_kp_data" || return 1
            printf '%s' "$_kp_name" > "$_kp_default_file"
            printf 'Default profile set to: %s\n' "$_kp_name"
            ;;

        which)
            shift
            if [ -n "${1:-}" ]; then
                _kp_name="$1"
                _kp_validate_name "$_kp_name" || return 1
                _kp_dir="${_kp_data}/${_kp_name}"
                if [ ! -d "$_kp_dir" ]; then
                    _kp_die "profile '${_kp_name}' does not exist. Create it with: kiro-profile create ${_kp_name}"
                    return 1
                fi
                printf '%s\n' "$_kp_dir"
            else
                if [ ! -f "$_kp_default_file" ]; then
                    _kp_die "no default profile set. Use: kiro-profile default <name>"
                    return 1
                fi
                _kp_name=$(cat "$_kp_default_file")
                if [ -z "$_kp_name" ]; then
                    _kp_die "default profile file is empty. Set one with: kiro-profile default <name>"
                    return 1
                fi
                _kp_dir="${_kp_data}/${_kp_name}"
                if [ ! -d "$_kp_dir" ]; then
                    _kp_die "profile '${_kp_name}' does not exist. Create it with: kiro-profile create ${_kp_name}"
                    return 1
                fi
                printf '%s\n' "$_kp_dir"
            fi
            ;;

        delete)
            shift
            if [ -z "${1:-}" ]; then
                _kp_die "usage: kiro-profile delete <name>"
                return 1
            fi
            _kp_name="$1"
            _kp_validate_name "$_kp_name" || return 1
            _kp_dir="${_kp_data}/${_kp_name}"
            if [ ! -d "$_kp_dir" ]; then
                _kp_die "profile '${_kp_name}' does not exist"
                return 1
            fi
            printf 'Delete profile "%s" and all its data (including login/session state)? [y/N] ' "$_kp_name"
            read -r _kp_confirm
            case "$_kp_confirm" in
                [yY]|[yY][eE][sS])
                    rm -rf "$_kp_dir"
                    printf 'Deleted profile: %s\n' "$_kp_name"
                    # Clear default if the deleted profile was the default
                    if [ -f "$_kp_default_file" ]; then
                        _kp_cur_default=$(cat "$_kp_default_file")
                        if [ "$_kp_cur_default" = "$_kp_name" ]; then
                            rm -f "$_kp_default_file"
                            printf 'Cleared default profile (was "%s")\n' "$_kp_name"
                        fi
                    fi
                    # Unset _KIRO_HOME if the deleted profile was active
                    if [ "${_KIRO_HOME:-}" = "$_kp_dir" ]; then
                        unset _KIRO_HOME
                        unset KIRO_PROFILE_AUTO_SET
                        printf 'Cleared active profile (was "%s")\n' "$_kp_name"
                    fi
                    ;;
                *)
                    printf 'Cancelled.\n'
                    ;;
            esac
            ;;

        version)
            _kp_installed_version
            ;;

        update)
            shift
            _kp_do_update "${1:-}"
            ;;

        help|-h|--help)
            cat <<'HELPEOF'
Usage: kiro-profile [command] [args...]

Commands:
    (no command)            Show current profile status
    use <name>              Switch session to the named profile (pins it)
    create [--init] [--from <dir>] <name>
                            Create a new profile. --init writes a settings/cli.json
                            skeleton; --from copies an existing directory into it.
    import [--from <dir>] <name>
                            Create a profile from an existing Kiro directory
                            (defaults to $_KIRO_HOME, else ~/.kiro)
    list, ls                List all profiles
    default [name]          Get or set the default profile
    local [name]            Show, set (.kiro-profile), or --remove the
                            directory-local profile for the current directory
    auto [on|off|status]    Control directory-local auto-switching
    which [name]            Show the resolved _KIRO_HOME path
    version                 Show the installed version
    update [--force]        Update to the latest release
    delete <name>           Delete a profile
    help, -h, --help        Show this help message

The kiro-cli command automatically uses the default profile. Use
'kiro-profile use <name>' to override for the current session. With no
profile and no default active, _KIRO_HOME is left unset and Kiro uses its
own default (~/.kiro).

A directory containing a .kiro-profile file (holding a profile name)
switches the shell to that profile on cd, and reverts on leaving. An
explicit 'kiro-profile use' pins the session and wins over any
.kiro-profile until 'kiro-profile auto on'. Set
KIRO_PROFILE_NO_AUTO_SWITCH=1 to disable, KIRO_PROFILE_AUTO_QUIET=1
to switch silently.

Examples:
    kiro-profile create work
    kiro-profile create --init work
    kiro-profile import work            # snapshot current ~/.kiro into "work"
    kiro-profile default work
    kiro-profile use work
    kiro-cli                        # runs with "work" profile
    kiro-profile                    # shows active/default status
    kiro-profile local work         # pin this directory tree to "work"
    kiro-profile local --remove     # drop the directory-local profile
HELPEOF
            ;;

        "")
            # Bare invocation: show status
            _kp_active=""
            if [ -n "${_KIRO_HOME:-}" ]; then
                case "${_KIRO_HOME%/}" in
                    "${_kp_data}"/*)
                        _kp_active=$(basename "${_KIRO_HOME%/}")
                        ;;
                esac
            fi
            if [ -n "$_kp_active" ]; then
                if [ "${_KIRO_HOME:-}" = "${KIRO_PROFILE_AUTO_SET:-}" ] && _kp_find_dotfile "${PWD:-}"; then
                    printf 'Active profile: %s (from %s)\n' "$_kp_active" "$_kp_dotfile"
                else
                    printf 'Active profile: %s\n' "$_kp_active"
                fi
                printf '_KIRO_HOME: %s\n' "$_KIRO_HOME"
            elif [ -n "${_KIRO_HOME:-}" ]; then
                printf 'Active _KIRO_HOME: %s (not a managed profile)\n' "$_KIRO_HOME"
            else
                printf 'No active profile (Kiro will use its default ~/.kiro)\n'
            fi
            _kp_cur_default=""
            if [ -f "$_kp_default_file" ]; then
                _kp_cur_default=$(cat "$_kp_default_file")
            fi
            if [ -n "$_kp_cur_default" ]; then
                printf 'Default profile: %s\n' "$_kp_cur_default"
            else
                printf 'No default profile set\n'
            fi
            ;;

        *)
            _kp_die "unknown command '$1'. Run 'kiro-profile help' for usage."
            return 1
            ;;
    esac
}
