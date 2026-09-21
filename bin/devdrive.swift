// Drives a running Tidsmaskinen instance through Accessibility, for looking at
// screens without a mouse: no screen coordinates, so it can't misfire into
// another app. Pair it with `screencapture -x -o -l <windowID> out.png`, which
// captures a window even when it is behind others.
//
//   swiftc -O -o build/devdrive bin/devdrive.swift
//   build/devdrive windows <pid>              # CGWindow id, layer, on-screen, name, bounds
//   build/devdrive dump <pid> [maxDepth]      # pressable elements: role | title | description | value | frame
//   build/devdrive press <pid> <substring>    # AXPress the first element whose title/description/value matches
//                                              ("role=AXMenuBarItem" matches by role, "title=Settings…" / "desc=All" exactly by title / description;
//                                              the app menu's Settings… item opens the main window without any keystroke)
//   build/devdrive set <pid> <substring> <v>  # set AXValue on the first matching element
//   build/devdrive select <pid> <substring>   # select the list row containing the first matching element
//   build/devdrive extras <pid>               # press the app's menu-bar status item (opens the tray popover)
import ApplicationServices
import CoreGraphics
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}
func str(_ e: AXUIElement, _ name: String) -> String {
    guard let v = attr(e, name) else { return "" }
    if let s = v as? String { return s }
    if CFGetTypeID(v) == AXValueGetTypeID() { return "" }
    return String("\(v)".prefix(60))
}
func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
}
func actions(_ e: AXUIElement) -> [String] {
    var a: CFArray?
    AXUIElementCopyActionNames(e, &a)
    return (a as? [String]) ?? []
}
func walk(_ e: AXUIElement, _ depth: Int, _ maxDepth: Int, _ visit: (AXUIElement, Int) -> Bool) {
    if depth > maxDepth || !visit(e, depth) { return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1, maxDepth, visit) }
    // The menu-bar status item lives in the extras bar, not under AXChildren.
    if depth == 0, let extras = attr(e, "AXExtrasMenuBar") { walk(extras as! AXUIElement, 1, maxDepth, visit) }
}
/// Match "role=AXMenuBarItem" against the role, anything else against title/description/value.
func matches(_ e: AXUIElement, _ needle: String) -> Bool {
    if needle.hasPrefix("role=") { return str(e, kAXRoleAttribute).lowercased() == needle.dropFirst(5).lowercased() }
    if needle.hasPrefix("title=") { return str(e, kAXTitleAttribute).lowercased() == needle.dropFirst(6).lowercased() }
    if needle.hasPrefix("desc=") { return str(e, kAXDescriptionAttribute).lowercased() == needle.dropFirst(5).lowercased() }
    return [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute)]
        .joined(separator: " | ").lowercased().contains(needle)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
    print("usage: devdrive windows|dump|press|select|set <pid> …"); exit(2)
}
let app = AXUIElementCreateApplication(pid)
switch args[1] {
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Int] ?? [:]
        print("id=\(w[kCGWindowNumber as String] ?? -1) layer=\(w[kCGWindowLayer as String] ?? -1) " +
              "onscreen=\(w[kCGWindowIsOnscreen as String] as? Bool ?? false) " +
              "name=\(w[kCGWindowName as String] as? String ?? "") " +
              "x=\(b["X"] ?? 0) y=\(b["Y"] ?? 0) w=\(b["Width"] ?? 0) h=\(b["Height"] ?? 0)")
    }
case "dump":
    let maxDepth = args.count > 3 ? Int(args[3]) ?? 40 : 40
    let shown: Set<String> = ["AXStaticText", "AXWindow", "AXSheet", "AXPopover", "AXTextField", "AXRadioButton"]
    walk(app, 0, maxDepth) { e, d in
        let role = str(e, kAXRoleAttribute)
        let title = str(e, kAXTitleAttribute), desc = str(e, kAXDescriptionAttribute), val = str(e, kAXValueAttribute)
        if actions(e).contains(kAXPressAction) || shown.contains(role) {
            if !(role == "AXStaticText" && title.isEmpty && val.isEmpty) {
                print(String(repeating: " ", count: d) + "\(role) | \(title) | \(desc) | \(val) | \(frame(e))")
            }
        }
        return true
    }
case "select":
    // Select the list/table row that contains the first matching element.
    guard args.count > 3 else { print("usage"); exit(2) }
    let needle = args[3].lowercased()
    var done = false
    walk(app, 0, 40) { e, _ in
        if done { return false }
        guard matches(e, needle) else { return true }
        var node: AXUIElement? = e
        while let n = node, str(n, kAXRoleAttribute) != "AXRow" {
            node = attr(n, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard let row = node else { print("no enclosing row for '\(needle)'"); done = true; return false }
        let r = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        print("select row containing '\(needle)' → \(r.rawValue)")
        done = true; return false
    }
    if !done { print("no match for '\(needle)'"); exit(1) }
case "extras":
    // Press the app's own menu-bar status item (its AXExtrasMenuBar child).
    guard let extras = attr(app, "AXExtrasMenuBar"),
          let item = (attr(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else {
        print("no status item"); exit(1)
    }
    print("press status item → \(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)")
case "press", "set":
    guard args.count > 3 else { print("usage"); exit(2) }
    let needle = args[3].lowercased()
    var done = false
    walk(app, 0, 40) { e, _ in
        if done { return false }
        guard matches(e, needle) else { return true }
        if args[1] == "press", actions(e).contains(kAXPressAction) {
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            print("press \(str(e, kAXRoleAttribute)) '\(str(e, kAXDescriptionAttribute))' → \(r.rawValue)")
            done = true; return false
        }
        if args[1] == "set", args.count > 4 {
            let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFString)
            print("set \(str(e, kAXRoleAttribute)) → \(r.rawValue)")
            done = true; return false
        }
        return true
    }
    if !done { print("no match for '\(needle)'"); exit(1) }
default:
    print("usage: devdrive windows|dump|press|select|set <pid> …"); exit(2)
}
