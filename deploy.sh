#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# WordPress Plugin Release Deployer (Git to SVN)
# ============================================================================
# Version: 0.2.2
# This script automates the process of releasing a WordPress plugin to the
# official WordPress plugin repository (wordpress.org/plugins).
# ============================================================================

# Resolve to actual path if script is run via symlink
# Works on both Linux (readlink -f) and macOS (need to resolve manually)
resolve_symlink() {
  local target="$1"
  cd "$(dirname "$target")"
  target="$(basename "$target")"
  while [[ -L "$target" ]]; do
    target="$(readlink "$target")"
    cd "$(dirname "$target")"
    target="$(basename "$target")"
  done
  echo "$(pwd -P)/$target"
}

SCRIPT_PATH="$(resolve_symlink "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

### CONFIG ###
ALLOWED_BRANCHES=("main" "master")
TMPROOT="$(mktemp -d)"

# Cleanup temp directory on exit (success or failure)
cleanup() {
  local exit_code=$?
  if [[ -d "$TMPROOT" ]]; then
    rm -rf "$TMPROOT"
  fi
  if [[ $exit_code -ne 0 ]]; then
    echo "Script failed with exit code $exit_code"
  fi
  exit $exit_code
}
trap cleanup EXIT

# Error handler - prints line number on error
error_handler() {
  echo "ERROR on line $1"
}
trap 'error_handler $LINENO' ERR
### END CONFIG ###

slugify() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s\n' "$text"
}

build_authenticated_remote_url() {
  local remote_url="$1"
  local username="$2"
  local password="$3"

  if [[ -z "$remote_url" || -z "$username" || -z "$password" ]]; then
    printf '%s\n' "$remote_url"
    return 0
  fi

  if [[ "$remote_url" =~ ^https?:// ]]; then
    if [[ "$remote_url" == *"@"* ]]; then
      printf '%s\n' "$remote_url"
      return 0
    fi

    local scheme="${remote_url%%://*}"
    local rest="${remote_url#*://}"
    local host="${rest%%/*}"
    local path="${rest#*/}"

    if [[ -z "$path" ]]; then
      printf '%s\n' "$remote_url"
      return 0
    fi

    printf '%s://%s:%s@%s/%s\n' "$scheme" "$username" "$password" "$host" "$path"
    return 0
  fi

  printf '%s\n' "$remote_url"
}

prepare_github_push_auth() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"

  if [[ "$remote_url" != https://* ]]; then
    return 0
  fi

  local username="${GITHUB_USERNAME:-}"
  local password="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

  if [[ -n "$username" && -n "$password" ]]; then
    GITHUB_PUSH_URL="$(build_authenticated_remote_url "$remote_url" "$username" "$password")"
    echo "Using GitHub credentials from the environment for the push step."
  else
    GITHUB_PUSH_URL=""
    echo "Using Git's configured credentials for the push step."
  fi
}

detect_plugin_slug() {
  local gitroot="$1"
  local candidate=""

  if [[ -f "$gitroot/readme.txt" ]]; then
    candidate="$(grep -iE 'Plugin Name' "$gitroot/readme.txt" 2>/dev/null | head -1 | sed -E 's/.*Plugin Name[[:space:]]*[:=]?[[:space:]]*//I' | tr -d '\r' | sed 's/[[:space:]]*$//' || true)"
    if [[ -n "$candidate" ]]; then
      candidate="$(slugify "$candidate")"
      if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  local php_file
  while IFS= read -r php_file; do
    if grep -qiE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$php_file"; then
      candidate="$(basename "$php_file")"
      candidate="${candidate%.php}"
      if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done < <(find "$gitroot" -maxdepth 1 -type f -name '*.php' | sort)

  local dirname
  dirname="$(basename "$gitroot")"
  if [[ -n "$dirname" && -f "$gitroot/$dirname.php" ]]; then
    printf '%s\n' "$dirname"
    return 0
  fi

  return 1
}

# Find git root from current working directory (where user called script from)
# This works whether script is called directly or via symlink.
GITROOT="$(git rev-parse --show-toplevel)"
cd "$GITROOT"
AUTO_PLUGIN_SLUG="$(detect_plugin_slug "$GITROOT" || true)"

# Collect user input
echo ""
echo "=============================================="
echo "WordPress Plugin Release Deployer (Git to SVN)"
echo "=============================================="
echo ""
if [[ -n "$AUTO_PLUGIN_SLUG" ]]; then
  read -rp "Plugin Slug (e.g., 'my-awesome-plugin') [$AUTO_PLUGIN_SLUG]: " PLUGINSLUG_INPUT
  PLUGINSLUG="${PLUGINSLUG_INPUT:-$AUTO_PLUGIN_SLUG}"
else
  read -rp "Plugin Slug (e.g., 'my-awesome-plugin'): " PLUGINSLUG
fi
read -rp "WordPress.org SVN Username: " SVNUSER
read -rsp "WordPress.org SVN Password/App Password: " SVNPASS
echo ""

# Define the SVN repository URL before any authentication checks use it.
SVNURL="https://plugins.svn.wordpress.org/$PLUGINSLUG"

# Reuse these flags for all SVN network operations so authentication is explicit
# and the script does not hang waiting for repeated interactive prompts.
SVN_AUTH_ARGS=(--non-interactive)
SVN_USERNAME_CANDIDATES=("$SVNUSER")
if [[ "$SVNUSER" == *@* ]]; then
  SVN_USERNAME_CANDIDATES+=("${SVNUSER%@*}")
fi

SVN_AUTH_OK=false
for candidate in "${SVN_USERNAME_CANDIDATES[@]}"; do
  if svn ls "${SVN_AUTH_ARGS[@]}" --username "$candidate" --password "$SVNPASS" "$SVNURL" >/dev/null 2>&1; then
    SVN_AUTH_OK=true
    SVNUSER="$candidate"
    break
  fi
done

if [[ "$SVN_AUTH_OK" != true ]]; then
  echo "SVN authentication failed."
  echo "WordPress.org requires a dedicated SVN username/password pair from your profile:"
  echo "https://profiles.wordpress.org/me/profile/edit/group/3/?screen=svn-password"
  echo "Use that generated SVN password (or an application password if required) and your WordPress.org username."
  exit 1
fi

SVN_AUTH_ARGS=(--non-interactive --username "$SVNUSER" --password "$SVNPASS")

SVNPATH="$TMPROOT/$PLUGINSLUG"
READMETXT="$GITROOT/readme.txt"
MAINFILE="$GITROOT/$PLUGINSLUG.php"

### PRE-FLIGHT CHECKS ###
# Validate environment and repository state before proceeding

cd "$GITROOT"

# # Debug: Show resolved paths
# echo "Git root: $GITROOT"
# echo "Looking for: $READMETXT"
# echo "Looking for: $MAINFILE"
# echo ""

# Ensure required files exist
[[ -f "$READMETXT" ]] || { echo "readme.txt not found at: $READMETXT"; exit 1; }
[[ -f "$MAINFILE" ]] || { echo "Main plugin file not found at: $MAINFILE"; exit 1; }

# Verify working directory is clean (no uncommitted changes)
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Git working tree is dirty. Commit or stash changes first."
  exit 1
fi

# Ensure we're on an allowed release branch
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BRANCH_OK=false
for b in "${ALLOWED_BRANCHES[@]}"; do
  [[ "$CURRENT_BRANCH" == "$b" ]] && BRANCH_OK=true
done
if [[ "$BRANCH_OK" != true ]]; then
  echo "Releases must be from one of: ${ALLOWED_BRANCHES[*]}"
  exit 1
fi

# Extract versions from readme.txt and main plugin file
# These must match exactly or the deploy will fail
# Use || true to prevent grep from triggering ERR trap when no match found
READMESTABLE=$(
  grep -i "Stable tag:" "$READMETXT" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r' | sed 's/[[:space:]]*$//' || true
)

PLUGINVERSION=$(
  grep -i "^[[:space:]]*\*\?[[:space:]]*Version:" "$MAINFILE" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r' | sed 's/[[:space:]]*$//' || true
)

# Verify versions were found
if [[ -z "$READMESTABLE" || -z "$PLUGINVERSION" ]]; then
  echo "Failed to extract version information."
  echo "  readme.txt stable tag: '$READMESTABLE'"
  echo "  plugin file version: '$PLUGINVERSION'"
  echo ""
  echo "First 20 lines of readme.txt:"
  head -20 "$READMETXT"
  echo ""
  echo "First 30 lines of plugin file:"
  head -30 "$MAINFILE"
  exit 1
fi

# Prevent accidental trunk deployment
if [[ "$READMESTABLE" == "trunk" ]]; then
  echo "Stable tag is 'trunk'. Refusing to deploy."
  exit 1
fi

# Ensure versions match between readme.txt and plugin header
if [[ "$READMESTABLE" != "$PLUGINVERSION" ]]; then
  echo "Version mismatch:"
  echo "  readme.txt:    $READMESTABLE"
  echo "  plugin header: $PLUGINVERSION"
  exit 1
fi

# Git tag uses "v" prefix (convention for git), SVN tag does NOT (WordPress convention)
GITTAG="v$READMESTABLE"
SVNTAG="$READMESTABLE"

# Check if git tag already exists (e.g., from a previously aborted deploy)
TAG_EXISTS=false
if git rev-parse "$GITTAG" >/dev/null 2>&1; then
  TAG_EXISTS=true
  echo ""
  echo "Git tag $GITTAG already exists."
  echo "This may be from a previously aborted deploy."
  echo ""
  echo "Options:"
  echo "  [r] Reuse existing tag (continue deploy with current tag)"
  echo "  [d] Delete and recreate tag (new commit message)"
  echo "  [a] Abort"
  echo ""
  read -rp "Choose [r/d/a]: " TAG_ACTION
  case "$TAG_ACTION" in
    r|R)
      echo "Reusing existing tag $GITTAG."
      COMMITMSG=$(git tag -l --format='%(contents)' "$GITTAG" | head -1)
      echo "Commit message from existing tag: $COMMITMSG"
      ;;
    d|D)
      read -rp "Release commit message: " COMMITMSG
      # Delete local and remote tag (remote may not exist if previous push failed)
      git tag -d "$GITTAG"
      git push origin ":refs/tags/$GITTAG" 2>/dev/null || true
      TAG_EXISTS=false
      ;;
    *)
      echo "Aborting."
      exit 1
      ;;
  esac
else
  read -rp "Release commit message: " COMMITMSG
fi

### GIT OPERATIONS ###
# Tag the release in git and push to remote origin

prepare_github_push_auth

if [[ "$TAG_EXISTS" != true ]]; then
  git tag -a "$GITTAG" -m "$COMMITMSG"
fi
# Push branch and tag (--force for tag in case remote already has it from a partial push)
if [[ -n "${GITHUB_PUSH_URL:-}" ]]; then
  git push "$GITHUB_PUSH_URL" "$CURRENT_BRANCH"
  git push "$GITHUB_PUSH_URL" "$GITTAG" --force
else
  git push origin "$CURRENT_BRANCH"
  git push origin "$GITTAG" --force
fi

### SVN OPERATIONS ###
# Check out the WordPress plugin SVN repository

svn checkout "${SVN_AUTH_ARGS[@]}" "$SVNURL" "$SVNPATH"

# Check if SVN tag already exists (prevent duplicate SVN releases)
if svn ls "${SVN_AUTH_ARGS[@]}" "$SVNURL/tags/$SVNTAG" >/dev/null 2>&1; then
  echo "SVN tag $SVNTAG already exists at $SVNURL/tags/$SVNTAG"
  echo "Aborting to prevent overwriting existing release."
  exit 1
fi

# Sync strategy: Remove all files from disk (not SVN), extract git archive,
# then let SVN detect changes. This properly handles:
# - New files (? status) -> svn add
# - Deleted files (! status) -> svn delete  
# - Modified files (M status) -> automatic
# - Unchanged files -> no action needed

if [[ -d "$SVNPATH/trunk" ]]; then
  # Remove all files from disk but preserve .svn metadata and directory structure
  find "$SVNPATH/trunk" -type f ! -path "*/.svn/*" -delete
  # Remove empty directories (except .svn)
  find "$SVNPATH/trunk" -type d -empty ! -name ".svn" ! -path "*/.svn/*" -delete 2>/dev/null || true
fi

# Ensure trunk directory exists (may not exist for new plugins or after cleanup)
mkdir -p "$SVNPATH/trunk"

# Export code from the immutable git tag to SVN trunk
# Using git archive ensures we get exactly what was tagged
# Run from git root to ensure relative paths are correct
(cd "$GITROOT" && git archive "$GITTAG" | tar -x -C "$SVNPATH/trunk")

# Remove .gitignore and .svnignore from SVN trunk (should not be deployed)
rm -f "$SVNPATH/trunk/.gitignore" "$SVNPATH/trunk/.svnignore"

# Remove files listed in both .gitignore and .svnignore from SVN trunk
# .gitignore: General exclusions (e.g., node_modules, .DS_Store)
# .svnignore: SVN-specific exclusions (e.g., src/, build/, deploy.sh)
for ignore_file in "$GITROOT/.gitignore" "$GITROOT/.svnignore"; do
  [[ ! -f "$ignore_file" ]] && continue
  
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    # Skip empty lines and comments
    [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
    # Remove leading/trailing whitespace
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -z "$pattern" ]] && continue
    # Skip negation patterns (gitignore syntax)
    [[ "$pattern" =~ ^! ]] && continue
    
    # Remove leading slash if present (gitignore root patterns)
    pattern="${pattern#/}"
    
    # Handle trailing slashes (directory patterns)
    # Convert patterns like "src/" to match directories properly
    if [[ "$pattern" == */ ]]; then
      # Directory pattern: use -type d and -path for directory matching
      dir_pattern="${pattern%/}"  # Remove trailing slash
      find "$SVNPATH/trunk" -type d -path "*/$dir_pattern" -o -path "$SVNPATH/trunk/$dir_pattern" | \
        while IFS= read -r dir; do
          [[ -n "$dir" ]] && rm -rf "$dir" 2>/dev/null || true
        done
    else
      # File or mixed pattern: use -path to match full paths, not just basenames
      # This handles patterns like "package.json" anywhere in the tree
      find "$SVNPATH/trunk" -path "*/$pattern" -o -path "$SVNPATH/trunk/$pattern" | \
        while IFS= read -r item; do
          [[ -n "$item" ]] && rm -rf "$item" 2>/dev/null || true
        done
    fi
  done < "$ignore_file"
done

# Configure SVN to ignore development files that shouldn't be in the repo
svn propset svn:ignore \
".git
.gitignore
deploy.sh
README.md" \
"$SVNPATH/trunk"

# Handle SVN file state changes:
# 1. Files marked as missing (!) - need to confirm deletion
# 2. Files marked as unversioned (?) - need to add
# 3. Files marked as deleted but restored - need to revert and re-add

# SVN status format: 7 status columns + space + filename (column 9 onwards)
# Using cut -c9- to extract filename properly handles spaces in filenames

# First, get list of missing files (deleted from disk but SVN still tracks)
# and confirm the deletion with svn delete
# Note: grep returns exit 1 if no matches, so we use { grep ... || true; } to prevent ERR trap
svn status "$SVNPATH/trunk" 2>/dev/null | { grep '^!' || true; } | cut -c9- | while IFS= read -r missing_file; do
  [[ -n "$missing_file" ]] && svn delete --force "$missing_file" 2>/dev/null || true
done

# Add new/untracked files to SVN
svn status "$SVNPATH/trunk" 2>/dev/null | { grep '^?' || true; } | cut -c9- | while IFS= read -r new_file; do
  [[ -n "$new_file" ]] && svn add "$new_file" 2>/dev/null || true
done

# Handle replaced files (file was deleted then re-added with new content)
# These show as 'R' in svn status and are handled automatically

# Handle WordPress.org assets (banner, icon, screenshots)
# These go in a separate 'assets' directory, not in trunk
if [[ -d "$SVNPATH/trunk/assets-wp-repo" ]]; then
  # Sanity check: ensure at least a banner image exists
  if ! ls "$SVNPATH/trunk/assets-wp-repo"/banner-* >/dev/null 2>&1; then
    echo "Warning: No banner asset found in assets-wp-repo/"
    read -rp "Continue without banner? [y/N] " CONFIRM_BANNER
    [[ "$CONFIRM_BANNER" == "y" ]] || exit 1
  fi

  # Create assets directory if it doesn't exist in SVN
  if [[ ! -d "$SVNPATH/assets" ]]; then
    mkdir -p "$SVNPATH/assets"
    svn add "$SVNPATH/assets"
  fi

  # Sync assets: copy new/updated files, remove deleted ones
  rsync -a --delete "$SVNPATH/trunk/assets-wp-repo/" "$SVNPATH/assets/"

  # Handle SVN state for assets directory
  # Add new files
  svn status "$SVNPATH/assets" 2>/dev/null | { grep '^?' || true; } | cut -c9- | while IFS= read -r new_file; do
    [[ -n "$new_file" ]] && svn add "$new_file" 2>/dev/null || true
  done

  # Remove deleted files
  svn status "$SVNPATH/assets" 2>/dev/null | { grep '^!' || true; } | cut -c9- | while IFS= read -r missing_file; do
    [[ -n "$missing_file" ]] && svn delete --force "$missing_file" 2>/dev/null || true
  done

  # Remove assets-wp-repo from trunk (it should not be deployed to WordPress.org trunk)
  svn delete --force "$SVNPATH/trunk/assets-wp-repo"
fi

# Display pending changes for review
echo
echo "=============================================="
echo "SVN Status (all pending changes):"
echo "=============================================="
svn status "$SVNPATH"
echo
echo "=============================================="
echo "SVN diff for trunk:"
echo "=============================================="
svn diff "$SVNPATH/trunk"
echo
echo "=============================================="
echo "Release Summary:"
echo "  Version: $SVNTAG"
echo "  Git tag: $GITTAG"
echo "  SVN tag: $SVNURL/tags/$SVNTAG"
echo "=============================================="
echo
read -rp "Proceed with SVN commit? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" ]] || exit 1

# Commit everything in the working copy (trunk + assets) in one atomic commit
# This ensures consistency between trunk and assets
svn commit "${SVN_AUTH_ARGS[@]}" "$SVNPATH" \
  -m "$COMMITMSG"

# Create a SVN tag (copy) pointing to the released version
# WordPress convention: tags are version numbers without "v" prefix (e.g., "1.0.0")
# This creates an immutable snapshot of trunk at this version
svn copy \
  "${SVN_AUTH_ARGS[@]}" \
  "$SVNURL/trunk" \
  "$SVNURL/tags/$SVNTAG" \
  -m "Tagging version $SVNTAG"

echo
echo "=============================================="
echo "Deployment complete!"
echo "  Plugin: $PLUGINSLUG"
echo "  Version: $SVNTAG"
echo "  SVN: $SVNURL/tags/$SVNTAG"
echo "=============================================="

