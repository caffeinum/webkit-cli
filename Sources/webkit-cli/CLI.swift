import Foundation

let helpText = """
  webkit-cli — drive the system WebKit headless, with persistent logged-in accounts.

  Log in once in a real window, then run headless forever after. No window ever appears
  except during `auth`.

  USAGE
    webkit-cli auth <url>                open a window at <url>; sign in; click Done to save
    webkit-cli open <url>                load and print {"url","title","status"}
    webkit-cli text <url>                print the page's innerText
    webkit-cli eval <url> '<js>'         run JS as an async function body, print the JSON result
    webkit-cli shot <url> <out.png>      save a 1280x800 screenshot (file mode 0600)
    webkit-cli accounts                  list saved accounts (JSON)
    webkit-cli forget <account>          delete an account and all its website data
    webkit-cli doctor                    check that headless pages really render (visible + rAF)

  Everything shares one default profile ("main") unless you pass --account. Sign in to as many
  sites as you like into it — `auth google.com`, then `auth github.com` — and every headless
  command after that is logged in to all of them, including "Sign in with Google/GitHub" flows.
  A <url> without a scheme gets https://.

  FLAGS
    -a, --account <name>  use a separate profile (letters, digits, . _ - @); `-` = throwaway,
                          in memory, saves nothing. Named profiles are created by `auth`.
    --wait <sec>          settle time after the page finishes loading (default 3)
    --timeout <sec>       give up after this long, exit 3 (default 60; `auth` never times out)
    -h, --help            this text

  EXAMPLES
    webkit-cli auth google.com                   # sign in to Google in a window, then close it
    webkit-cli auth github.com                   # same profile, now GitHub too
    webkit-cli open https://console.cloud.google.com
    webkit-cli eval https://github.com/settings/tokens 'return document.title'
    webkit-cli text example.com --account -
    webkit-cli auth railway.com --account work   # a second identity
    webkit-cli shot https://railway.com/dashboard /tmp/railway.png --account work
    webkit-cli eval example.com --wait 0 '
      document.querySelector("a").click();
      await new Promise(r => setTimeout(r, 2000));
      return location.href'

  `eval` code is the body of an async function: use `return` to produce output, `await` freely.
  Fill React inputs with the native setter, then dispatch input/change:
    const i = document.querySelector("input[name=name]");
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, "my-key");
    i.dispatchEvent(new Event("input", {bubbles: true}));
    i.form.requestSubmit();

  Account data: ~/Library/WebKit/webkit-cli/WebsiteDataStore/<uuid> (keyed by the binary name —
  do not rename the binary). Names → uuids and saved session cookies: ~/.config/webkit-cli (0700).
  Cookies are credentials: never print them, never share that directory.

  Exit codes: 0 ok, 1 error, 2 usage, 3 timeout.
  """

enum Command {
  case help
  case accounts
  case auth(account: String, url: URL)
  case open(account: String, url: URL)
  case text(account: String, url: URL)
  case eval(account: String, url: URL, js: String)
  case shot(account: String, url: URL, out: URL)
  case forget(account: String)
  case doctor
}

/// The profile used when no --account is given. Named "main" so logins made with v1's
/// `auth main <url>` are the default profile without any migration.
let defaultAccount = "main"

struct Options {
  var wait: Double = 3
  var timeout: Double = 60
  var account: String = defaultAccount
}

func parseArguments(_ args: [String]) throws -> (Command, Options) {
  var opts = Options()
  var positional: [String] = []
  var i = 0
  while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
      return (.help, opts)
    case "--wait", "--timeout":
      guard i + 1 < args.count, let v = Double(args[i + 1]), v >= 0, v.isFinite else {
        throw CLIError("\(a) needs a number of seconds", code: ExitCode.usage)
      }
      if a == "--wait" { opts.wait = v } else { opts.timeout = v }
      i += 2
      continue
    case "-a", "--account":
      guard i + 1 < args.count else { throw CLIError("\(a) needs an account name", code: ExitCode.usage) }
      opts.account = args[i + 1]
      i += 2
      continue
    default:
      if a.hasPrefix("--") { throw CLIError("unknown flag \(a) (see --help)", code: ExitCode.usage) }
      positional.append(a)
    }
    i += 1
  }

  guard let verb = positional.first else { return (.help, opts) }
  let rest = Array(positional.dropFirst())
  func need(_ n: Int, _ usage: String) throws {
    guard rest.count == n else { throw CLIError("usage: webkit-cli \(usage)", code: ExitCode.usage) }
  }
  let account = opts.account

  switch verb {
  case "help":
    return (.help, opts)
  case "accounts":
    try need(0, "accounts")
    return (.accounts, opts)
  case "auth":
    try need(1, "auth <url> [--account <name>]")
    guard account != "-" else { throw CLIError("auth needs a saved account — `-` keeps nothing", code: ExitCode.usage) }
    return (.auth(account: account, url: try parseURL(rest[0])), opts)
  case "open":
    try need(1, "open <url>")
    return (.open(account: account, url: try parseURL(rest[0])), opts)
  case "text":
    try need(1, "text <url>")
    return (.text(account: account, url: try parseURL(rest[0])), opts)
  case "eval":
    try need(2, "eval <url> '<js>'")
    return (.eval(account: account, url: try parseURL(rest[0]), js: rest[1]), opts)
  case "shot":
    try need(2, "shot <url> <out.png>")
    let out = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)
    return (.shot(account: account, url: try parseURL(rest[0]), out: out), opts)
  case "forget":
    try need(1, "forget <account>")
    return (.forget(account: rest[0]), opts)
  case "doctor":
    try need(0, "doctor")
    return (.doctor, opts)
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
