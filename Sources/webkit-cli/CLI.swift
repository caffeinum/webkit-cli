import Foundation

let helpText = """
  webkit-cli — drive the system WebKit headless, with persistent logged-in profiles.

  Log in once in a real window, then run headless forever after. No window ever appears
  except during `auth`.

  SIGN IN
    webkit-cli auth <url>                   open a window at <url>; sign in; click Done to save

  TABS (live between commands — for multi-page flows like OAuth)
    webkit-cli open <url>                   open a tab → {"tab","url","title","status"}
    webkit-cli click <tab> <selector>       click; waits for any navigation it starts
    webkit-cli type <tab> <selector> <text> set an input's value (React-safe) — never echoed
    webkit-cli wait <tab> [--until-url <regex>] [--until-selector <css>]
    webkit-cli goto <tab> <url>             navigate an open tab
    webkit-cli text <tab>                   innerText
    webkit-cli eval <tab> '<js>'            run JS as an async function body, print the JSON result
    webkit-cli shot <tab> <out.png>         1280x800 viewport screenshot (PNG at 2x on Retina, mode 0600)
    webkit-cli tabs                         list open tabs (popups appear as their own tabs)
    webkit-cli close <tab>
    webkit-cli stop                         end the profile's session now (saves cookies)

  WHEN A PERSON IS NEEDED (the only other time a window appears — always opt-in)
    webkit-cli show <tab> [--reason <text>] put that live tab on screen with a Done bar
    webkit-cli hide <tab>                   back to headless (Done, ⌘W and the close button do this too)
    webkit-cli wait <tab> --until-hidden    until the person clicks Done (or --until-url/-selector holds)
    --escalate on click/wait/goto           if the tab (or its popup) lands on a challenge page — Google
                                            "verify it's you", GitHub 2FA, a visible captcha — show it,
                                            wait for the person to get past it, hide it, carry on

  ONE-SHOT (a URL instead of a tab: load it in a temporary tab, act, close)
    webkit-cli text <url>
    webkit-cli eval <url> '<js>'
    webkit-cli shot <url> <out.png>

  PROFILES
    webkit-cli accounts                     list saved profiles (JSON)
    webkit-cli forget <account>             delete a profile and all its website data
    webkit-cli doctor                       check that headless pages really render (visible + rAF)

  Everything shares one default profile ("main") unless you pass --account. Sign in to as many
  sites as you like into it — `auth google.com`, then `auth github.com` — and every headless
  command after that is logged in to all of them, including "Sign in with Google/GitHub" flows.
  A <url> without a scheme gets https://.

  Tabs live in a background session process per profile, started by the first command and
  ended after --idle seconds without commands (default 900) or by `stop`.

  <selector> is CSS (`button[type=submit]`, `#email`) or `text=<words>` to match a visible
  button/link/option by its text (exact match first, then the shortest one containing it).

  FLAGS
    -a, --account <name>    use a separate profile (letters, digits, . _ - @); `-` = throwaway,
                            in memory, one-shot only. Named profiles are created by `auth`.
    --wait <sec>            settle time after a load/click (default: open/goto/one-shot 3,
                            click 1, others 0)
    --timeout <sec>         give up after this long, exit 3 (default 60; `auth` never times out)
    --until-url <regex>     `wait` until the tab's URL matches
    --until-selector <css>  `wait` until an element matching <css> exists
    --idle <sec>            idle timeout for a session this command starts (default 900)
    --challenge-url <regex> with --escalate: also treat matching URLs as challenges (repeatable)
    --human-timeout <sec>   with --escalate: how long to wait for the person (default 600, exit 3
                            after); time spent waiting for a person doesn't count toward --timeout
    --out <file>            write `eval`/`text` output to <file> (mode 0600) instead of stdout,
                            and print only {"written","bytes"} — for API keys and other secrets
    --raw                   `eval`: when the result is a string, output it without JSON quotes
    -h, --help              this text

  EXAMPLES
    webkit-cli auth google.com                   # sign in to Google in a window, click Done
    tab=$(webkit-cli open https://cloud.browser-use.com/signin | jq -r .tab)
    webkit-cli click $tab 'text=Continue with Google'
    webkit-cli wait $tab --until-url '^https://cloud\\.browser-use\\.com/(?!signin)' --timeout 90
    webkit-cli text $tab
    webkit-cli close $tab
    webkit-cli eval https://github.com/settings/tokens 'return document.title'
    webkit-cli text example.com --account -

  `eval` code is the body of an async function: use `return` to produce output, `await` freely.
  It dies if the page navigates mid-script — use `click` + `wait` for steps that change page.

  Account data: ~/Library/WebKit/webkit-cli/WebsiteDataStore/<uuid> (keyed by the binary name —
  do not rename the binary). Names → uuids, saved session cookies and session sockets:
  ~/.config/webkit-cli (0700). Cookies are credentials: never print them, never share that directory.

  Exit codes: 0 ok, 1 error, 2 usage, 3 timeout.
  """

enum Command {
  case help
  case accounts
  case auth(account: String, url: URL)
  case forget(account: String)
  case doctor
  case stop(account: String)
  case serve(account: String, idle: Double)
  case session(account: String, request: Request)
}

/// The profile used when no --account is given. Named "main" so logins made with v1's
/// `auth main <url>` are the default profile without any migration.
let defaultAccount = "main"

struct Options {
  var wait: Double?
  var timeout: Double = 60
  var account: String = defaultAccount
  var idle: Double = defaultIdleSeconds
  var untilURL: String?
  var untilSelector: String?
  var out: String?
  var raw = false
  var reason: String?
  var untilHidden = false
  var escalate = false
  var challengeURLs: [String] = []
  var humanTimeout: Double?
}

func parseArguments(_ args: [String]) throws -> (Command, Options) {
  var opts = Options()
  var positional: [String] = []
  var i = 0
  func value(_ flag: String) throws -> String {
    guard i + 1 < args.count else { throw CLIError("\(flag) needs a value", code: ExitCode.usage) }
    return args[i + 1]
  }
  func seconds(_ flag: String) throws -> Double {
    guard let v = Double(try value(flag)), v >= 0, v.isFinite else {
      throw CLIError("\(flag) needs a number of seconds", code: ExitCode.usage)
    }
    return v
  }
  while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help": return (.help, opts)
    case "--raw", "--until-hidden", "--escalate":
      if a == "--raw" { opts.raw = true } else if a == "--until-hidden" { opts.untilHidden = true } else { opts.escalate = true }
      i += 1
      continue
    case "--reason": opts.reason = try value(a)
    case "--challenge-url":
      let pattern = try value(a)
      guard (try? NSRegularExpression(pattern: pattern)) != nil else {
        throw CLIError("--challenge-url is not a valid regex: \(pattern)", code: ExitCode.usage)
      }
      opts.challengeURLs.append(pattern)
    case "--human-timeout": opts.humanTimeout = try seconds(a)
    case "--wait": opts.wait = try seconds(a)
    case "--timeout": opts.timeout = try seconds(a)
    case "--idle": opts.idle = try seconds(a)
    case "-a", "--account": opts.account = try value(a)
    case "--until-url": opts.untilURL = try value(a)
    case "--until-selector": opts.untilSelector = try value(a)
    case "--out": opts.out = URL(fileURLWithPath: (try value(a) as NSString).expandingTildeInPath).standardizedFileURL.path
    default:
      if a.hasPrefix("--") { throw CLIError("unknown flag \(a) (see --help)", code: ExitCode.usage) }
      positional.append(a)
      i += 1
      continue
    }
    i += 2
  }

  guard let verb = positional.first else { return (.help, opts) }
  let rest = Array(positional.dropFirst())
  func need(_ n: Int, _ usage: String) throws {
    guard rest.count == n else { throw CLIError("usage: webkit-cli \(usage)", code: ExitCode.usage) }
  }
  let account = opts.account
  func session(_ cmd: String, target: String? = nil, url: String? = nil, js: String? = nil, selector: String? = nil,
               text: String? = nil, path: String? = nil) -> Command {
    .session(account: account, request: Request(
      cmd: cmd, target: target, url: url, js: js, selector: selector, text: text, path: path,
      untilURL: opts.untilURL, untilSelector: opts.untilSelector, wait: opts.wait, timeout: opts.timeout,
      untilHidden: opts.untilHidden ? true : nil, escalate: opts.escalate ? true : nil,
      challengeURLs: opts.challengeURLs.isEmpty ? nil : opts.challengeURLs, humanTimeout: opts.humanTimeout))
  }
  func tabOrURL(_ s: String) throws -> String { isTabID(s) ? s : try parseURL(s).absoluteString }
  func tabID(_ s: String) throws -> String {
    guard isTabID(s) else { throw CLIError("expected a tab id like t3f9a2c (from `webkit-cli open <url>`), got '\(s)'", code: ExitCode.usage) }
    return s
  }

  let tabCommands: Set = ["open", "goto", "tabs", "click", "type", "wait", "close", "stop", "show", "hide"]
  if account == "-" && tabCommands.contains(verb) {
    throw CLIError("--account - is one-shot only (text/eval/shot <url>); \(verb) needs a saved profile's session", code: ExitCode.usage)
  }
  if opts.escalate || !opts.challengeURLs.isEmpty || opts.humanTimeout != nil {
    guard ["click", "wait", "goto"].contains(verb) else {
      throw CLIError("--escalate/--challenge-url/--human-timeout work with click, wait and goto on a tab", code: ExitCode.usage)
    }
    guard opts.escalate else { throw CLIError("--challenge-url/--human-timeout need --escalate", code: ExitCode.usage) }
  }

  switch verb {
  case "help":
    return (.help, opts)
  case "accounts":
    try need(0, "accounts")
    return (.accounts, opts)
  case "auth":
    try need(1, "auth <url> [--account <name>]")
    guard account != "-" else { throw CLIError("auth needs a saved profile — `-` keeps nothing", code: ExitCode.usage) }
    return (.auth(account: account, url: try parseURL(rest[0])), opts)
  case "forget":
    try need(1, "forget <account>")
    return (.forget(account: rest[0]), opts)
  case "doctor":
    try need(0, "doctor")
    return (.doctor, opts)
  case "stop":
    try need(0, "stop [--account <name>]")
    return (.stop(account: account), opts)
  case "serve":
    try need(0, "serve [--account <name>] [--idle <sec>]")
    return (.serve(account: account, idle: opts.idle), opts)
  case "open":
    try need(1, "open <url>")
    return (session("open", url: try parseURL(rest[0]).absoluteString), opts)
  case "goto":
    try need(2, "goto <tab> <url>")
    return (session("goto", target: try tabID(rest[0]), url: try parseURL(rest[1]).absoluteString), opts)
  case "tabs":
    try need(0, "tabs")
    return (session("tabs"), opts)
  case "text":
    try need(1, "text <tab|url>")
    return (session("text", target: try tabOrURL(rest[0])), opts)
  case "eval":
    try need(2, "eval <tab|url> '<js>'")
    return (session("eval", target: try tabOrURL(rest[0]), js: rest[1]), opts)
  case "shot":
    try need(2, "shot <tab|url> <out.png>")
    let out = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath).standardizedFileURL.path
    return (session("shot", target: try tabOrURL(rest[0]), path: out), opts)
  case "click":
    try need(2, "click <tab> <selector>")
    return (session("click", target: try tabID(rest[0]), selector: rest[1]), opts)
  case "type":
    try need(3, "type <tab> <selector> <text>")
    return (session("type", target: try tabID(rest[0]), selector: rest[1], text: rest[2]), opts)
  case "wait":
    try need(1, "wait <tab> [--until-url <regex>] [--until-selector <css>]")
    return (session("wait", target: try tabID(rest[0])), opts)
  case "show":
    try need(1, "show <tab> [--reason <text>]")
    return (session("show", target: try tabID(rest[0]), text: opts.reason), opts)
  case "hide":
    try need(1, "hide <tab>")
    return (session("hide", target: try tabID(rest[0])), opts)
  case "close":
    try need(1, "close <tab>")
    return (session("close", target: try tabID(rest[0])), opts)
  default:
    throw CLIError("unknown command '\(verb)' (see --help)", code: ExitCode.usage)
  }
}

func parseURL(_ s: String) throws -> URL {
  let hasScheme = s.contains("://") || s.hasPrefix("about:")
  guard let url = URL(string: hasScheme ? s : "https://" + s), url.host != nil || url.scheme == "about" || url.scheme == "file" else {
    throw CLIError("not a URL: \(s)", code: ExitCode.usage)
  }
  return url
}
