#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "ERROR on line $LINENO"; exit 1' ERR

# ============================================================================
# WordPress Plugin Release Deployer (Git to SVN)
# ============================================================================
# This script automates the process of releasing a WordPress plugin to the
# official WordPress plugin repository (wordpress.org/plugins).
#
# REQUIREMENTS:
#   - Git repository with commits you want to release
#   - SVN client installed (svn command)
#   - WordPress.org plugin repository access (SVN credentials)
#   - readme.txt with "Stable tag:" version
#   - Main plugin file (.php) with "Version:" header
#
# WORKFLOW:
#   1. Validates your git state and version consistency
#   2. Creates a git tag and pushes to origin
#   3. Checks out the WordPress SVN repository
#   4. Syncs code, handles asset files, and updates version
#   5. Commits changes to SVN repository
#   6. Tags the release in SVN
#
# ============================================================================


### CONFIG ###
ALLOWED_BRANCHES=("main" "master")
TMPROOT="$(mktemp -d)"
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

GITROOT="$(git rev-parse --show-toplevel)"
SVNPATH="$TMPROOT/$PLUGINSLUG"
SVNURL="https://plugins.svn.wordpress.org/$PLUGINSLUG"

READMETXT="$GITROOT/readme.txt"
MAINFILE="$GITROOT/$PLUGINSLUG.php"

### PRE-FLIGHT CHECKS ###
# Validate environment and repository state before proceeding

cd "$GITROOT"

# Ensure required files exist
[[ -f "$READMETXT" ]] || { echo "readme.txt not found"; exit 1; }
[[ -f "$MAINFILE" ]] || { echo "Main plugin file not found"; exit 1; }

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
READMESTABLE=$(
  awk -F': *' '/^Stable tag:/ {
    gsub(/[[:space:]]+$/, "", $2);
    print $2
  }' "$READMETXT"
)

PLUGINVERSION=$(
  awk -F': *' '/^Version:/ {
    gsub(/[[:space:]]+$/, "", $2);
    print $2;
    exit
  }' "$MAINFILE"
)

# Verify versions were found
if [[ -z "$READMESTABLE" || -z "$PLUGINVERSION" ]]; then
  echo "Failed to extract version information."
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

TAG="v$READMESTABLE"

# Prevent duplicate releases - ensure git tag doesn't already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Git tag $TAG already exists."
  exit 1
fi

read -rp "Release commit message: " COMMITMSG

### GIT OPERATIONS ###
# Tag the release in git and push to remote origin

git tag -a "$TAG" -m "$COMMITMSG"
git push origin "$CURRENT_BRANCH"
git push origin "$TAG"

### SVN OPERATIONS ###
# Check out the WordPress plugin SVN repository

svn checkout "$SVNURL" "$SVNPATH"

# Export code from the immutable git tag to SVN trunk
# Using git archive ensures we get exactly what was tagged
git archive "$TAG" | tar -x -C "$SVNPATH/trunk"

# Remove .gitignore from SVN trunk (should not be deployed)
rm -f "$SVNPATH/trunk/.gitignore"

# Remove files listed in .gitignore from SVN trunk
# (in case any were committed to git but should not go to SVN)
if [[ -f "$GITROOT/.gitignore" ]]; then
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
  done < "$GITROOT/.gitignore"
fi

# Configure SVN to ignore development files that shouldn't be in the repo
svn propset svn:ignore \
".git
.gitignore
deploy.sh
README.md" \
"$SVNPATH/trunk"

# Remove files that were deleted in git but still exist in SVN
svn status "$SVNPATH/trunk" | sed -n 's/^! *//p' | while IFS= read -r f; do
  svn delete "$f"
done

# Add new files that are in git but not yet in SVN
svn status "$SVNPATH/trunk" | sed -n 's/^? *//p' | while IFS= read -r f; do
  svn add "$f"
done

# Handle WordPress.org assets (banner, icon, screenshots)
# These go in a separate 'assets' directory, not in trunk
if [[ -d "$SVNPATH/trunk/assets-wp-repo" ]]; then
  # Sanity check: ensure at least a banner image exists
  if ! ls "$SVNPATH/trunk/assets-wp-repo"/banner-* >/dev/null 2>&1; then
    echo "No banner asset found. Aborting to prevent asset wipe."
    exit 1
  fi

  # Copy assets from git directory to SVN assets directory
  mkdir -p "$SVNPATH/assets"
  rsync -a --delete "$SVNPATH/trunk/assets-wp-repo/" "$SVNPATH/assets/"
  svn add "$SVNPATH/assets" --force
  svn delete "$SVNPATH/trunk/assets-wp-repo"
fi

# Display pending changes for review
echo
echo "SVN diff for trunk:"
svn diff "$SVNPATH/trunk"
echo
read -rp "Proceed with SVN commit? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" ]] || exit 1

# Commit the trunk (main plugin code)
svn commit "$SVNPATH/trunk" \
  --username "$SVNUSER" \
  -m "$COMMITMSG"

# Commit assets separately (if any exist)
if [[ -d "$SVNPATH/assets" ]]; then
  svn commit "$SVNPATH/assets" \
    --username "$SVNUSER" \
    -m "Update plugin assets"
fi

# Create a SVN tag (immutable snapshot) pointing to the released version
# This is a full repository copy, which in SVN acts as a tag
svn copy \
  "$SVNURL/trunk" \
  "$SVNURL/tags/$READMESTABLE" \
  -m "Tag $READMESTABLE" \
  --username "$SVNUSER"

# Clean up temporary files
rm -rf "$TMPROOT"

echo "Deployment complete."

