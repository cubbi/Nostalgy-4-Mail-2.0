import Foundation

/// A Mail mailbox, identified by account name ("" = On My Mac) and slash-separated path.
struct Mailbox: Hashable {
    let account: String
    let path: String

    var leaf: String { path.split(separator: "/").last.map(String.init) ?? path }
    var display: String { (account.isEmpty ? "On My Mac" : account) + " / " + path.replacingOccurrences(of: "/", with: " / ") }

    var encoded: String { account + "\t" + path }

    init(account: String, path: String) {
        self.account = account
        self.path = path
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        self.init(account: String(parts[0]), path: String(parts[1]))
    }
}

struct MailError: Error, CustomStringConvertible {
    let number: Int
    let message: String
    var description: String { "\(message) (\(number))" }

    static let noSelection = 1001
    static let notAuthorized = -1743
}

enum MailBridge {
    // MARK: - Running scripts

    @discardableResult
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MailError(number: -1, message: "Could not compile AppleScript")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            throw MailError(
                number: info[NSAppleScript.errorNumber] as? Int ?? -1,
                message: info[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            )
        }
        return result
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func reference(_ m: Mailbox) -> String {
        m.account.isEmpty
            ? "mailbox \(quote(m.path))"
            : "mailbox \(quote(m.path)) of account \(quote(m.account))"
    }

    // MARK: - Listing mailboxes

    private static let listScript = """
    -- Some servers report a child's name with its parent's path already in it.
    on joinPath(prefix, n)
        if prefix is "" then return n
        if n starts with (prefix & "/") then return n
        return prefix & "/" & n
    end joinPath

    -- Path of mb's parent mailboxes ("" for a top-level mailbox).
    -- The parent must be fetched before asking its class: "class of (container of mb)"
    -- in one expression reports "container" for every mailbox. A nested mailbox's parent
    -- has class "container" (not "mailbox"); a top-level one's parent is its account.
    on parentPath(mb)
        tell application "Mail"
            try
                set par to container of mb
                set k to class of par
            on error
                return ""
            end try
            if k is not container and k is not mailbox then return ""
            set n to name of par
        end tell
        return my joinPath(my parentPath(par), n)
    end parentPath

    on walk(mbs, prefix, acct)
        set out to {}
        tell application "Mail"
            repeat with mb in mbs
                set p to my joinPath(prefix, name of mb)
                set end of out to acct & tab & p
                set out to out & my walk(mailboxes of mb, p, acct)
            end repeat
        end tell
        return out
    end walk

    -- Mail lists nested mailboxes alongside their parents, and sometimes leaves a parent
    -- out (e.g. Gmail's "[Gmail]"). Walk from each mailbox whose parent is not listed,
    -- keeping the parent's path, so every mailbox appears once with its full path.
    on walkAll(mbs, acct)
        set parents to {}
        set paths to {}
        repeat with mb in mbs
            set pp to my parentPath(mb)
            tell application "Mail" to set n to name of mb
            set end of parents to pp
            set end of paths to my joinPath(pp, n)
        end repeat
        set out to {}
        repeat with i from 1 to count of mbs
            set pp to item i of parents
            if pp is "" or paths does not contain {pp} then
                set out to out & my walk({item i of mbs}, pp, acct)
            end if
        end repeat
        return out
    end walkAll

    set res to {}
    tell application "Mail" to set accts to every account
    repeat with a in accts
        tell application "Mail"
            set isOn to enabled of a
            set aName to name of a
            set mbs to mailboxes of a
        end tell
        if isOn then set res to res & my walkAll(mbs, aName)
    end repeat
    tell application "Mail" to set localMbs to mailboxes
    set res to res & my walkAll(localMbs, "")
    set AppleScript's text item delimiters to linefeed
    return res as text
    """

    /// Reads Mail's folders on a background thread and calls `completion` on the main thread.
    /// Uses osascript in a child process because NSAppleScript should only run on the main thread,
    /// and listing folders can take several seconds.
    static func listMailboxes(completion: @escaping (Result<[Mailbox], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> [Mailbox] in
                var out: [Mailbox] = []
                var seen = Set<Mailbox>()
                for line in try runOsascript(listScript).split(separator: "\n") {
                    if let m = Mailbox(encoded: String(line)), seen.insert(m).inserted { out.append(m) }
                }
                return out
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runOsascript(_ source: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] // read the script from stdin
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            // e.g. "12:34: execution error: Not authorized to send Apple events to Mail. (-1743)"
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var number = -1
            if let r = message.range(of: #"\((-?\d+)\)$"#, options: .regularExpression) {
                number = Int(message[r].dropFirst().dropLast()) ?? -1
            }
            let text = message.components(separatedBy: "execution error: ").last ?? message
            throw MailError(number: number, message: text.isEmpty ? "osascript failed" : text)
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    // MARK: - Actions on the selected messages

    /// Finds the message to select after the selection is moved away: the nearest message below
    /// it in the list, or else the nearest one above. Returns {mailbox, message id} or missing value.
    /// Mail's "visible messages" and "sort column" fail on current macOS, so the list order is
    /// taken to be by date received, top to bottom as "sorted ascending" says (newest on top by default).
    private static let nextMessageHandler = """
    on nextMessage(sel)
        tell application "Mail"
            -- Look in what the viewer shows (e.g. "All Inboxes" spans several accounts);
            -- fall back to the selected message's own mailbox.
            set pools to {}
            try
                set pools to selected mailboxes of message viewer 1
            end try
            if (count of pools) is 0 then set pools to {mailbox of item 1 of sel}
            set asc to false
            try
                set asc to sorted ascending of message viewer 1
            end try
            set selIDs to {}
            set lo to missing value
            set hi to missing value
            repeat with m in sel
                set end of selIDs to id of m
                set d to date received of m
                if lo is missing value or d < lo then set lo to d
                if hi is missing value or d > hi then set hi to d
            end repeat
        end tell
        -- "older" = the nearest message dated before the selection, "newer" = the nearest after it.
        -- Each is kept with the mailbox it was found in, to select it after the move.
        set older to missing value
        set olderD to missing value
        set newer to missing value
        set newerD to missing value
        repeat with mb in pools
            set mb to contents of mb
            try
                tell application "Mail"
                    set ids to id of messages of mb
                    set ds to date received of messages of mb
                end tell
            on error
                set ids to {}
            end try
            repeat with i from 1 to count of ids
                set mid to item i of ids
                if selIDs does not contain {mid} then
                    set d to item i of ds
                    if d ≤ lo and (olderD is missing value or d > olderD) then
                        set older to {mb, mid}
                        set olderD to d
                    else if d ≥ hi and (newerD is missing value or d < newerD) then
                        set newer to {mb, mid}
                        set newerD to d
                    end if
                end if
            end repeat
        end repeat
        if asc then
            set belowPick to newer
            set abovePick to older
        else
            set belowPick to older
            set abovePick to newer
        end if
        if belowPick is not missing value then return belowPick
        return abovePick
    end nextMessage
    """

    private static func onSelection(_ verb: String, to m: Mailbox, selectNext: Bool = false) throws {
        try run("""
        \(selectNext ? nextMessageHandler : "")
        tell application "Mail"
            set target to \(reference(m))
            set sel to selection
            if (count of sel) is 0 then error "No messages selected." number \(MailError.noSelection)
            set nxt to missing value
            \(selectNext ? "try\n set nxt to my nextMessage(sel)\n end try" : "")
            repeat with msg in sel
                \(verb) msg to target
            end repeat
            if nxt is not missing value then
                try
                    set selected messages of message viewer 1 to {first message of (item 1 of nxt) whose id is (item 2 of nxt)}
                end try
            end if
        end tell
        """)
    }

    static func move(to m: Mailbox) throws { try onSelection("move", to: m, selectNext: true) }
    static func copy(to m: Mailbox) throws { try onSelection("duplicate", to: m) }

    static func go(to m: Mailbox) throws {
        try run("""
        tell application "Mail"
            set target to \(reference(m))
            if (count of message viewers) is 0 then make new message viewer
            set selected mailboxes of message viewer 1 to {target}
        end tell
        """)
    }
}
