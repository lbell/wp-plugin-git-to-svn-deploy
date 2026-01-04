#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# WordPress Plugin Release Deployer (Git to SVN)
# ============================================================================
# Version: 0.2.1
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

# Collect user input
echo ""
echo "=============================================="
echo "WordPress Plugin Release Deployer (Git to SVN)"
echo "=============================================="
echo ""
read -rp "Plugin Slug (e.g., 'my-awesome-plugin'): " PLUGINSLUG
read -rp "SVN Username (your wordpress.org username): " SVNUSER
echo ""

# Find git root from current working directory (where user called script from)
# This works whether script is called directly or via symlink
GITROOT="$(git rev-parse --show-toplevel)"
SVNPATH="$TMPROOT/$PLUGINSLUG"
SVNURL="https://plugins.svn.wordpress.org/$PLUGINSLUG"

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

# Prevent duplicate releases - ensure git tag doesn't already exist
if git rev-parse "$GITTAG" >/dev/null 2>&1; then
  echo "Git tag $GITTAG already exists."
  exit 1
fi

read -rp "Release commit message: " COMMITMSG

### GIT OPERATIONS ###
# Tag the release in git and push to remote origin

git tag -a "$GITTAG" -m "$COMMITMSG"
git push origin "$CURRENT_BRANCH" "$GITTAG"

### SVN OPERATIONS ###
# Check out the WordPress plugin SVN repository

svn checkout "$SVNURL" "$SVNPATH"

# Check if SVN tag already exists (prevent duplicate SVN releases)
if svn ls "$SVNURL/tags/$SVNTAG" >/dev/null 2>&1; then
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
    # Find and remove matching files/directories in trunk
    # Use find with -name for simple patterns, handle negation patterns
    [[ "$pattern" =~ ^! ]] && continue  # Skip negation patterns
    # Remove leading slash if present (gitignore root patterns)
    pattern="${pattern#/}"
    # Find matching files and remove them
    find "$SVNPATH/trunk" -name "$pattern" -exec rm -rf {} + 2>/dev/null || true
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
svn commit "$SVNPATH" \
  --username "$SVNUSER" \
  -m "$COMMITMSG"

# Create a SVN tag (copy) pointing to the released version
# WordPress convention: tags are version numbers without "v" prefix (e.g., "1.0.0")
# This creates an immutable snapshot of trunk at this version
svn copy \
  "$SVNURL/trunk" \
  "$SVNURL/tags/$SVNTAG" \
  -m "Tagging version $SVNTAG" \
  --username "$SVNUSER"

echo
echo "=============================================="
echo "Deployment complete!"
echo "  Plugin: $PLUGINSLUG"
echo "  Version: $SVNTAG"
echo "  SVN: $SVNURL/tags/$SVNTAG"
echo "=============================================="

