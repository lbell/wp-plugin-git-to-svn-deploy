# WordPress Plugin Git to SVN Deployer

Version: 0.2.1

A robust bash script that automates deploying WordPress plugin releases from a Git repository to the official WordPress.org plugin SVN repository.

## Features

- **Version validation** - Ensures version consistency between `readme.txt` and plugin header
- **Git tagging** - Automatically creates and pushes Git tags
- **SVN synchronization** - Syncs code changes, handles file additions/deletions
- **Asset management** - Properly handles WordPress.org assets (banners, icons, screenshots)
- **Safety checks** - Validates clean working tree, allowed branches, and prevents duplicate releases

## Requirements

- Git repository with your plugin code
- SVN client installed (`svn` command)
- WordPress.org plugin repository credentials
- `readme.txt` with `Stable tag:` version
- Main plugin file with `Version:` header

## Usage

```bash
./deploy.sh
```

The script will prompt you for:

- Plugin slug
- WordPress.org username
- Release commit message

## Workflow

1. Validates your git state and version consistency
2. Creates a git tag and pushes to origin
3. Checks out the WordPress SVN repository
4. Syncs code and handles asset files
5. Commits changes to SVN repository
6. Tags the release in SVN

## Configuration

- **Allowed branches**: `main`, `master` (modify `ALLOWED_BRANCHES` in script)
- **Assets directory**: Place WordPress.org assets in `assets-wp-repo/` directory (banners, icons, screenshots)
- **File exclusions**: Create a `.svnignore` file to exclude files from SVN deployment

### File Exclusion Strategy

The script reads from **both** `.gitignore` and `.svnignore` when deploying to SVN:

- **`.gitignore`**: General exclusions that shouldn't be in any repo (e.g., `node_modules/`, `.DS_Store`)
- **`.svnignore`**: SVN-specific exclusions for files needed in Git but not in wordpress.org distribution (e.g., `src/`, `build/`, `deploy.sh`)

**Example `.svnignore`:**

```
src/
build/
deploy.sh
README.md
```

This allows you to keep development files in Git while excluding them from WordPress.org SVN distribution.

## Notes

- The script automatically ignores `.git`, `.gitignore`, `.svnignore`, `deploy.sh`, and `README.md` from SVN
- Requires a clean working tree (no uncommitted changes)
- Versions must match exactly between `readme.txt` and main plugin file
