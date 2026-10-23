import Foundation
@testable import HerdrKit

// Remote herdr (Settings): the saved machines, which one the app shows, and what goes into the settings store.
@MainActor func checksRemoteSettings() async throws {
    let suite = "flockbook.checks.machines.\(getpid())"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "machines: a defaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }

    // Round trip: add, select, load again from the same store.
    var m = RemoteMachines(defaults: d)
    check(m.machines.isEmpty && m.selected == nil, "machines: empty store -> no machines, This Mac")
    let a = try m.add(destination: "dev@build-box", session: "work", label: "Build box")
    let b = try m.add(destination: "laptop-alias", session: nil, label: "  ")
    try m.select(a.id)
    let again = RemoteMachines(defaults: d)
    check(again.machines == [a, b], "machines: saved machines come back in order (\(again.machines))")
    check(again.selected == a.id && again.selectedMachine == a, "machines: the selected machine comes back")
    check(b.label == nil && b.title == "laptop-alias", "machines: a blank label is no label; the title is the destination (\(b.title))")
    check(a.title == "Build box" && a.detail == "dev@build-box · work", "machines: title is the label, detail the destination and session")

    // Edit and remove.
    try m.update(b.id, destination: "laptop-alias", session: "test-1", label: "Laptop")
    check(RemoteMachines(defaults: d).machines.last?.session == "test-1", "machines: an edit is saved")
    m.remove(a.id)
    check(m.selected == nil && RemoteMachines(defaults: d).selected == nil, "machines: removing the selected machine selects This Mac")
    check(m.machines.map(\.id) == [b.id], "machines: remove drops the machine")
    try m.select(nil)
    var threw = false
    do { try m.select("no-such-id") } catch { threw = true }
    check(threw && m.selected == nil, "machines: selecting an unknown id is refused")

    // Refusals: what ssh could read as an option, white space, shell characters; bad herdr session names.
    for bad in ["-oProxyCommand=sh", "user@host extra", "host;rm", "$(id)@host", "host`id`", "", "a/b", "host\n", "user:secret@host"] {
        var refused = false
        do { _ = try m.add(destination: bad, session: nil, label: nil) } catch { refused = true }
        check(refused, "machines: destination refused: \(bad.debugDescription)")
    }
    for bad in ["a/b", "..", ".", "-x", "with space", "s;x", "$(id)", "a\u{0}b", String(repeating: "s", count: 65)] {
        check(RemoteMachines.sessionNameProblem(bad) != nil, "machines: session name refused: \(bad.debugDescription)")
        var refused = false
        do { _ = try m.add(destination: "host", session: bad, label: nil) } catch { refused = true }
        check(refused, "machines: add refuses session \(bad.debugDescription)")
    }
    check(RemoteMachines.problem(destination: "user@[fe80::1%en0]", session: nil) == nil, "machines: an IPv6 destination with a user is fine")
    for good in ["c9-input-test", "work_2", "v1.2"] { check(RemoteMachines.sessionNameProblem(good) == nil, "machines: session name ok: \(good)") }
    var dup = false
    do { _ = try m.add(destination: "laptop-alias", session: "test-1", label: "again") } catch { dup = true }
    check(dup, "machines: the same destination and session twice is refused")
    let count = m.machines.count
    do { try m.update(b.id, destination: "-oX", session: nil, label: nil) } catch {}
    check(m.machines.count == count && m.machines.first { $0.id == b.id }?.destination == "laptop-alias", "machines: a refused edit changes nothing")
    let long = try m.add(destination: "h2", session: nil, label: String(repeating: "L", count: 200) + "\n")
    check((long.label?.count ?? 0) <= RemoteMachines.labelLimit && long.label?.contains("\n") == false, "machines: a label is one short line")
    m.remove(long.id)

    // Selection -> the session the app shows. Launch flags win; no flag: the selected machine; none: herdr on this Mac.
    try m.select(b.id)
    let picked = RemoteMachines.launchSession(arguments: ["app"], environment: [:], defaults: d)
    check(picked.remote == RemoteHost(via: .ssh(destination: "laptop-alias")) && picked.name == "test-1",
          "machines: the selected machine decides the session (\(picked))")
    check(picked == HerdrSession.remote(RemoteHost(via: .ssh(destination: "laptop-alias")), name: "test-1"), "machines: same relay socket as HerdrSession.remote")
    let flag = RemoteMachines.launchSession(arguments: ["app", "--session", "c9-input-test"], environment: [:], defaults: d)
    check(flag.remote == nil && flag.name == "c9-input-test", "machines: --session wins over the saved machine")
    let rflag = RemoteMachines.launchSession(arguments: ["app", "--remote-local"], environment: [:], defaults: d)
    check(rflag.remote == RemoteHost(via: .local), "machines: --remote-local wins over the saved machine")
    let env = RemoteMachines.launchSession(arguments: ["app"], environment: ["HERDR_DESK_SESSION": "x"], defaults: d)
    check(env.remote == nil && env.name == "x", "machines: env HERDR_DESK_SESSION wins over the saved machine")
    try m.select(nil)
    let mac = RemoteMachines.launchSession(arguments: ["app"], environment: [:], defaults: d)
    check(mac == .default(), "machines: This Mac selected -> herdr's default session here")
    check(RemoteMachines.title(for: picked, defaults: d) == "Laptop", "machines: the window names a saved machine by its label")
    check(RemoteMachines.title(for: .default(), defaults: d) == nil, "machines: no machine name for this Mac")
    check(RemoteMachines.title(for: .remote(RemoteHost(via: .ssh(destination: "other")), name: nil), defaults: d) == "other",
          "machines: a machine from --remote is named by its destination")

    // A stored entry someone edited by hand is dropped, not passed to ssh.
    d.set(Data(#"{"machines":[{"id":"x","destination":"-oProxyCommand=sh"},{"id":"y","destination":"ok-host","session":"a/b"}],"selected":"x"}"#.utf8),
          forKey: RemoteMachines.key)
    let hand = RemoteMachines(defaults: d)
    check(hand.machines.isEmpty && hand.selected == nil, "machines: invalid stored entries are dropped (\(hand.machines))")
    check(RemoteMachines.launchSession(arguments: ["app"], environment: [:], defaults: d) == .default(), "machines: a dropped selection shows this Mac")
    d.set(Data("not json".utf8), forKey: RemoteMachines.key)
    check(RemoteMachines(defaults: d).machines.isEmpty, "machines: unreadable store -> no machines")
    d.removeObject(forKey: RemoteMachines.key)

    // Nothing but the listed fields is stored: one key, top keys machines/selected, machine keys id/label/destination/session.
    var p = RemoteMachines(defaults: d)
    let c = try p.add(destination: "user@host", session: "s1", label: "Lab")
    try p.select(c.id)
    let keys = Set((d.persistentDomain(forName: suite) ?? [:]).keys)
    check(keys == [RemoteMachines.key], "machines: one defaults key (\(keys))")
    let raw = d.data(forKey: RemoteMachines.key) ?? Data()
    let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    check(Set(obj.keys).isSubset(of: ["machines", "selected"]) && obj["machines"] != nil, "machines: stored top keys (\(obj.keys.sorted()))")
    let items = obj["machines"] as? [[String: Any]] ?? []
    check(items.count == 1 && items.allSatisfy { Set($0.keys).isSubset(of: ["id", "label", "destination", "session"]) },
          "machines: stored machine keys (\(items.map { $0.keys.sorted() }))")
    check(items.allSatisfy { $0.values.allSatisfy { $0 is String } }, "machines: every stored value is a string")

    // The Test button's answer: `remote-api-bridge --check` through host.run, read into one line.
    let host = RemoteHost(via: .local)
    let okRun = try await host.run("echo herdr-api-bridge-v1", timeout: .seconds(10))
    let ok = RemoteMachines.testOutcome(okRun, destination: "h")
    check(ok.ok && ok.text.contains("herdr"), "machines test: the bridge's banner -> ok (\(ok.text))")
    let missing = try await host.run("echo \(RemoteHost.quote(RemoteHost.herdrMissingMarker)) >&2; exit 127", timeout: .seconds(10))
    let miss = RemoteMachines.testOutcome(missing, destination: "h")
    check(!miss.ok && miss.text.contains("not installed"), "machines test: no herdr on the host (\(miss.text))")
    func fake(_ status: Int32, _ err: String) -> RemoteHost.Result { RemoteHost.Result(status: status, stdout: Data(), stderr: err) }
    let hk = RemoteMachines.testOutcome(fake(255, "Host key verification failed.\n"), destination: "dev@box")
    check(!hk.ok && hk.text.contains("ssh dev@box"), "machines test: host key -> accept it once in Terminal (\(hk.text))")
    let auth = RemoteMachines.testOutcome(fake(255, "dev@box: Permission denied (publickey).\n"), destination: "dev@box")
    check(!auth.ok && auth.text.contains("ssh-add"), "machines test: refused login -> ssh-add (\(auth.text))")
    let late = RemoteMachines.testOutcome(fake(-1, ""), destination: "h")
    check(!late.ok && late.text.contains("No answer"), "machines test: timeout (\(late.text))")
    let other = RemoteMachines.testOutcome(fake(1, "some error\nmore"), destination: "h")
    check(!other.ok && other.text.contains("some error") && !other.text.contains("\n"), "machines test: other errors -> first stderr line (\(other.text))")
    let wrong = RemoteMachines.testOutcome(RemoteHost.Result(status: 0, stdout: Data("hello".utf8), stderr: ""), destination: "h")
    check(!wrong.ok, "machines test: exit 0 without the bridge banner is not ok")
    check(RemoteMachines.testCommand(session: "s1").contains("'remote-api-bridge' '--check'")
          && RemoteMachines.testCommand(session: "s1").contains("'--session' 's1'"), "machines test: the command line quotes every word")
}
