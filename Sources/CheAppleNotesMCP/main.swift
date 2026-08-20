import Foundation
import MCP

if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print(AppVersion.versionString)
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(AppVersion.helpMessage)
    exit(0)
}

if CommandLine.arguments.contains("--setup") {
    if ProcessInfo.processInfo.environment["TERM"] == nil || getppid() == 1 {
        print("WARNING: --setup appears to be running in a non-interactive session.")
        print("Permission dialogs cannot appear here. Run this command from Terminal.app instead.\n")
    }

    print("CheAppleNotesMCP Setup — probing permissions...\n")

    // 1. Probe SQLite (Full Disk Access)
    let sqliteOK = Capabilities.probeSQLiteAccess()
    if sqliteOK {
        print("SQLite read access: ✓ granted (fast path enabled)")
    } else {
        print("SQLite read access: ✗ denied (will use AppleScript fallback — slower)")
        print("  To enable the fast read path, grant Full Disk Access:")
        print("    1. Open System Settings → Privacy & Security → Full Disk Access")
        print("    2. Click + and add: ~/bin/CheAppleNotesMCP")
        print("    3. Restart any process that uses this binary\n")
    }

    // 2. Probe + request Automation (Notes.app)
    print("Requesting Automation permission for Notes.app...")
    let asOK = Capabilities.probeAppleScriptAccess()
    if asOK {
        print("Automation (Notes.app): ✓ granted\n")
    } else {
        print("Automation (Notes.app): ✗ denied or cancelled")
        print("  System Settings → Privacy & Security → Automation → CheAppleNotesMCP → Notes.app\n")
    }

    if sqliteOK && asOK {
        print("All set. You can now use che-apple-notes-mcp.")
    } else {
        print("Some permissions are missing. The server will still run but with reduced capability.")
    }
    exit(0)
}

if CommandLine.arguments.contains("--cli") {
    let server = await CheAppleNotesMCPServer()
    await CLIRunner.run(server: server, args: CommandLine.arguments)
    exit(0)
}

let server = await CheAppleNotesMCPServer()
try await server.run()
