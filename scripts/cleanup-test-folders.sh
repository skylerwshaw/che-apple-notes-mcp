#!/usr/bin/env bash
# Escape hatch for E2E test folders that survived teardown.
# Iterates every account in Notes.app, finds folders whose name starts with
# the fixture prefix `__CheMCPTest_`, and deletes them (plus contained notes).
#
# Usage: ./scripts/cleanup-test-folders.sh
#
# Safety: only folders whose name starts with `__CheMCPTest_` are touched.
# The prefix alone is the match — tests also create suffixed names
# (`...__container`, `...__sub`, `...__todelete`, `...__renamed`) that an
# ends-with check would miss, which is how orphans survived this script.
# Deleted notes land in Notes' "Recently Deleted" and auto-purge after 30
# days; they are not purged here because test note titles are too generic
# to distinguish from real notes safely.

set -euo pipefail

osascript <<'APPLESCRIPT'
tell application "Notes"
    set deletedCount to 0
    repeat with a in accounts
        set folderList to folders of a
        repeat with f in folderList
            set fname to name of f
            if fname starts with "__CheMCPTest_" then
                -- Delete notes inside first (delete folder refuses if non-empty)
                set noteList to notes of f
                repeat with n in noteList
                    delete n
                end repeat
                delete f
                set deletedCount to deletedCount + 1
            end if
        end repeat
    end repeat
    return "Deleted " & deletedCount & " fixture folders."
end tell
APPLESCRIPT
