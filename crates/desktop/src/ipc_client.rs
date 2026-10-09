// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/ipc/client.rs (the Msg command tree, run, to_request, parse_region,
// resolve_output_path, stream_events, print_response, print_state) and the
// argument grammar docs/cli.md generates from it. Arguments are parsed by hand
// instead of by clap, and the socket is Infinify's own.
//! The `msg` client: connect to a running Infinify's IPC socket, send one
//! request, print the reply. It never touches a controller.
use super::ipc::{Event, Reply, Request, Response, ScreenshotTarget, StateInfo, WindowSelector};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

const USAGE: &str = "\
Usage: infinify msg [--json] [--socket PATH] <command> [arguments]

Send one command to the running Infinify over its IPC socket: --socket PATH,
else $INFINIFY_SOCKET, else ~/Library/Application Support/Infinify/infinify.sock.
A command that fails prints an error to stderr and exits non-zero.

Commands:
  state                               Dump camera, zoom, and the window inventory
  subscribe                           Stream state snapshots as they change
  focus [APP_ID] [--id ID]            Print the focused window, or focus one
  move [X] [Y] [--id ID]              Get a window's position, or move it (frame center, Y-up)
  resize [WIDTH] [HEIGHT] [--id ID]   Get a window's size, or resize it
  close [APP_ID] [--id ID]            Close the focused window, or one by app id or id
  opacity [VALUE] [--id ID]           Get a window's opacity, or set it (0 to 1)
  pin [on|off] [--id ID]              Get whether a window is pinned to the screen, or set it
  suspend [APP_ID] [--id ID]          Suspend the focused window, or one by app id or id
  relaunch [APP_ID] [--id ID]         Relaunch a suspended window
  camera [X] [Y]                      Get the camera position, or pan to a canvas point (Y-up)
  zoom [LEVEL]                        Get the zoom level, or set it
  bookmark [NAME] [X] [Y] [--delete]  List bookmarks, get or set one, or delete it
  layout [--short]                    Print the active keyboard layout
  action <SPEC>...                    Run a config action, e.g. `action go-to-bookmark 1`
  screenshot [--scale S] [-o PATH] [window [APP_ID] [--id ID] | all | region X Y W H [--from-screen]]
                                      Capture a canvas PNG
  debug-counters                      Print internal collection sizes (unstable keys)

Options:
  --json         Print the raw JSON reply
  --socket PATH  Connect to this socket
  -h, --help     Print this help
";

/// Why the client stops without having printed a reply.
enum Stop {
    Help,
    /// What clap would refuse: exit status 2.
    Usage(String),
    /// A request the client will not send, a connection failure, or an `Err`
    /// reply: exit status 1.
    Failed(String),
    /// Exit status 1 with the reply already printed, as `--json` does.
    Reported,
}
fn usage<T>(message: impl Into<String>) -> Result<T, Stop> {
    Err(Stop::Usage(message.into()))
}
fn failed(message: impl ToString) -> Stop {
    Stop::Failed(message.to_string())
}

#[derive(Default)]
struct Global {
    json: bool,
    socket: Option<PathBuf>,
}
/// One subcommand's arguments, split the way its clap definition would.
struct Args {
    positionals: Vec<String>,
    options: BTreeMap<&'static str, String>,
}
impl Args {
    /// At most `count` positionals, each optional.
    fn at_most(&self, count: usize) -> Result<(), Stop> {
        match self.positionals.get(count) {
            Some(extra) => usage(format!("unexpected argument '{extra}'")),
            None => Ok(()),
        }
    }
    fn positional<T: std::str::FromStr>(
        &self,
        index: usize,
        name: &str,
    ) -> Result<Option<T>, Stop> {
        self.positionals
            .get(index)
            .map(|value| parse(value, name))
            .transpose()
    }
    fn id(&self) -> Result<Option<u64>, Stop> {
        self.options
            .get("--id")
            .map(|value| parse(value, "--id <ID>"))
            .transpose()
    }
    /// A window by `[APP_ID]` or `--id`, which exclude each other.
    fn selector(&self) -> Result<Option<WindowSelector>, Stop> {
        self.at_most(1)?;
        match (self.id()?, self.positionals.first()) {
            (Some(_), Some(_)) => usage("the argument '--id <ID>' cannot be used with '[APP_ID]'"),
            (Some(id), None) => Ok(Some(WindowSelector::Id(id))),
            (None, Some(app_id)) => Ok(Some(WindowSelector::AppId(app_id.clone()))),
            (None, None) => Ok(None),
        }
    }
}
fn parse<T: std::str::FromStr>(value: &str, name: &str) -> Result<T, Stop> {
    value
        .parse()
        .map_err(|_| Stop::Usage(format!("invalid value '{value}' for '{name}'")))
}
/// `-400` and `-.5` are values where a command allows negative numbers.
fn is_negative_number(token: &str) -> bool {
    token
        .strip_prefix('-')
        .and_then(|rest| rest.chars().next())
        .is_some_and(|c| c.is_ascii_digit() || c == '.')
}
/// Split `args` into positionals and the options the command declares: `flags`
/// take no value, `values` take one, as `--name VALUE` or `--name=VALUE`.
/// `--json` and `--socket` are accepted here as well as before the command.
fn split(
    args: &[String],
    flags: &[&'static str],
    values: &[&'static str],
    negative_numbers: bool,
    global: &mut Global,
) -> Result<Args, Stop> {
    let mut parsed = Args {
        positionals: Vec::new(),
        options: BTreeMap::new(),
    };
    let mut literal = false;
    let mut tokens = args.iter();
    while let Some(token) = tokens.next() {
        if literal || !token.starts_with('-') || token == "-" {
            parsed.positionals.push(token.clone());
            continue;
        }
        let (name, inline) = match token.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_string())),
            _ => (token.as_str(), None),
        };
        // `-o` is the one short option upstream defines.
        let name = if name == "-o" { "--output" } else { name };
        let mut value = |what: &str| match inline.clone().or_else(|| tokens.next().cloned()) {
            Some(value) => Ok(value),
            None => usage(format!("a value is required for '{what}'")),
        };
        if name == "--" {
            literal = true;
        } else if name == "-h" || name == "--help" {
            return Err(Stop::Help);
        } else if name == "--json" && inline.is_none() {
            global.json = true;
        } else if name == "--socket" {
            global.socket = Some(PathBuf::from(value("--socket <PATH>")?));
        } else if let Some(known) = values.iter().find(|known| **known == name) {
            let value = value(known)?;
            if parsed.options.insert(*known, value).is_some() {
                return usage(format!(
                    "the argument '{known}' cannot be used multiple times"
                ));
            }
        } else if let Some(known) = flags.iter().find(|known| **known == name) {
            if inline.is_some() {
                return usage(format!("the argument '{known}' takes no value"));
            }
            parsed.options.insert(*known, String::new());
        } else if negative_numbers && is_negative_number(token) {
            parsed.positionals.push(token.clone());
        } else {
            return usage(format!("unexpected argument '{token}'"));
        }
    }
    Ok(parsed)
}

/// What to send, and how the reply is consumed.
struct Invocation {
    request: Request,
    /// `screenshot -o -`: relay the written PNG to stdout, then delete it.
    stdout_capture: bool,
}
impl From<Request> for Invocation {
    fn from(request: Request) -> Self {
        Self {
            request,
            stdout_capture: false,
        }
    }
}
/// Both coordinates or neither; a lone one is refused by the client.
fn pair<T>(first: Option<T>, second: Option<T>, lone: &str) -> Result<Option<(T, T)>, Stop> {
    match (first, second) {
        (None, None) => Ok(None),
        (Some(first), Some(second)) => Ok(Some((first, second))),
        _ => Err(failed(lone)),
    }
}
fn to_invocation(command: &str, rest: &[String], global: &mut Global) -> Result<Invocation, Stop> {
    let request = match command {
        "state" | "subscribe" | "debug-counters" => {
            split(rest, &[], &[], false, global)?.at_most(0)?;
            match command {
                "state" => Request::State,
                "subscribe" => Request::Subscribe,
                _ => Request::DebugCounters,
            }
        }
        "focus" | "close" | "suspend" | "relaunch" => {
            let selector = split(rest, &[], &["--id"], false, global)?.selector()?;
            match command {
                "focus" => Request::Focus(selector),
                "close" => Request::Close(selector),
                "suspend" => Request::Suspend(selector),
                _ => Request::Relaunch(selector),
            }
        }
        "move" => {
            let args = split(rest, &[], &["--id"], true, global)?;
            args.at_most(2)?;
            Request::Move {
                window: args.id()?.map(WindowSelector::Id),
                to: pair(
                    args.positional::<i32>(0, "[X]")?,
                    args.positional::<i32>(1, "[Y]")?,
                    "move needs both <x> and <y>",
                )?,
            }
        }
        "resize" => {
            let args = split(rest, &[], &["--id"], false, global)?;
            args.at_most(2)?;
            let to = pair(
                args.positional::<i32>(0, "[WIDTH]")?,
                args.positional::<i32>(1, "[HEIGHT]")?,
                "resize needs both <width> and <height>",
            )?;
            if to.is_some_and(|(width, height)| width <= 0 || height <= 0) {
                return Err(failed("resize needs a positive <width> and <height>"));
            }
            Request::Resize {
                window: args.id()?.map(WindowSelector::Id),
                to,
            }
        }
        "opacity" => {
            let args = split(rest, &[], &["--id"], false, global)?;
            args.at_most(1)?;
            let value = args.positional::<f64>(0, "[VALUE]")?;
            // serde_json serializes non-finite floats as null, which the server
            // would read back as a get instead of rejecting — refuse them here.
            if value.is_some_and(|v| !v.is_finite()) {
                return Err(failed("opacity must be between 0.0 and 1.0"));
            }
            Request::Opacity {
                window: args.id()?.map(WindowSelector::Id),
                value,
            }
        }
        "pin" => {
            let args = split(rest, &[], &["--id"], false, global)?;
            args.at_most(1)?;
            // clap's boolish literals.
            let value = match args
                .positionals
                .first()
                .map(|v| v.to_lowercase())
                .as_deref()
            {
                None => None,
                Some("y" | "yes" | "t" | "true" | "on" | "1") => Some(true),
                Some("n" | "no" | "f" | "false" | "off" | "0") => Some(false),
                Some(other) => return usage(format!("invalid value '{other}' for '[on|off]'")),
            };
            Request::Pin {
                window: args.id()?.map(WindowSelector::Id),
                value,
            }
        }
        "camera" => {
            let args = split(rest, &[], &[], true, global)?;
            args.at_most(2)?;
            let to = pair(
                args.positional::<f64>(0, "[X]")?,
                args.positional::<f64>(1, "[Y]")?,
                "camera needs both <x> and <y>",
            )?;
            // As for opacity, and beyond upstream's client, which sends these:
            // the nulls then fail to decode as a camera write.
            if to.is_some_and(|(x, y)| !x.is_finite() || !y.is_finite()) {
                return Err(failed("camera coordinates must be finite numbers"));
            }
            Request::Camera(to)
        }
        "zoom" => {
            let args = split(rest, &[], &[], false, global)?;
            args.at_most(1)?;
            let level = args.positional::<f64>(0, "[LEVEL]")?;
            // Likewise beyond upstream's client, where the null reads the zoom
            // back and the command succeeds having set nothing.
            if level.is_some_and(|v| !v.is_finite()) {
                return Err(failed("zoom must be a positive number"));
            }
            Request::Zoom(level)
        }
        "bookmark" => {
            let args = split(rest, &["--delete"], &[], true, global)?;
            args.at_most(3)?;
            let name = args.positionals.first().cloned();
            let x = args.positional::<f64>(1, "[X]")?;
            let y = args.positional::<f64>(2, "[Y]")?;
            let delete = args.options.contains_key("--delete");
            if delete && name.is_none() {
                return usage("the following required arguments were not provided: <NAME>");
            }
            if delete && x.is_some() {
                return usage("the argument '--delete' cannot be used with '[X]'");
            }
            if x.is_some() && y.is_none() {
                return usage("the following required arguments were not provided: <Y>");
            }
            // As for opacity: a non-finite float would arrive as a get.
            if x.is_some_and(|v| !v.is_finite()) || y.is_some_and(|v| !v.is_finite()) {
                return Err(failed("bookmark coordinates must be finite"));
            }
            Request::Bookmark {
                name,
                to: x.zip(y),
                delete,
            }
        }
        "layout" => {
            let args = split(rest, &["--short"], &[], false, global)?;
            args.at_most(0)?;
            Request::Layout {
                short: args.options.contains_key("--short"),
            }
        }
        // Everything after `action` is the spec, exactly as written in config.
        "action" => match rest {
            [first, ..] if first == "-h" || first == "--help" => return Err(Stop::Help),
            [first, spec @ ..] if first == "--" && !spec.is_empty() => {
                Request::Action(spec.join(" "))
            }
            [] => return usage("the following required arguments were not provided: <SPEC>..."),
            spec => Request::Action(spec.join(" ")),
        },
        "screenshot" => return screenshot(rest, global),
        other => return usage(format!("unrecognized subcommand '{other}'")),
    };
    Ok(request.into())
}
fn screenshot(rest: &[String], global: &mut Global) -> Result<Invocation, Stop> {
    let args = split(
        rest,
        &["--from-screen"],
        &["--scale", "--output", "--id"],
        true,
        global,
    )?;
    let kind = args.positionals.first().map(String::as_str);
    let only = |option: &str, owner: &str| match args.options.contains_key(option) {
        true if kind != Some(owner) => usage(format!("unexpected argument '{option}'")),
        _ => Ok(()),
    };
    only("--id", "window")?;
    only("--from-screen", "region")?;
    let target = match kind {
        None => ScreenshotTarget::Viewport,
        Some("window") => {
            let window = Args {
                positionals: args.positionals[1..].to_vec(),
                options: args.options.clone(),
            };
            ScreenshotTarget::Window {
                window: window.selector()?,
            }
        }
        Some("all") => {
            args.at_most(1)?;
            ScreenshotTarget::All
        }
        Some("region") => {
            let coords = &args.positionals[1..];
            if coords.is_empty() {
                return usage("the following required arguments were not provided: <COORDS>...");
            }
            if let Some(extra) = coords.get(4) {
                return usage(format!("unexpected argument '{extra}'"));
            }
            let (x, y, w, h) = parse_region(coords).map_err(Stop::Failed)?;
            ScreenshotTarget::Region {
                x,
                y,
                w,
                h,
                from_screen: args.options.contains_key("--from-screen"),
            }
        }
        Some(other) => return usage(format!("unrecognized subcommand '{other}'")),
    };
    let output = args.options.get("--output");
    Ok(Invocation {
        request: Request::Screenshot {
            target,
            scale: match args.options.get("--scale") {
                Some(scale) => parse(scale, "--scale <SCALE>")?,
                None => 1.0,
            },
            path: resolve_output_path(output.map(String::as_str)).map_err(Stop::Failed)?,
        },
        stdout_capture: output.is_some_and(|o| o == "-"),
    })
}
/// Parse a region rectangle, accepting both `X Y W H` and slurp's native
/// `X,Y WxH`. The comma and `x` separators are normalized to spaces.
fn parse_region(tokens: &[String]) -> Result<(i32, i32, i32, i32), String> {
    let normalized = tokens.join(" ").replace([',', 'x'], " ");
    let nums = normalized
        .split_whitespace()
        .map(|t| t.parse::<i32>().map_err(|_| t.to_string()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|bad| {
            format!("region: '{bad}' is not an integer (expected X Y W H, or slurp's X,Y WxH)")
        })?;
    match nums.as_slice() {
        [x, y, w, h] => Ok((*x, *y, *w, *h)),
        _ => Err(format!(
            "region needs 4 values (X Y W H, or slurp's X,Y WxH), got {}",
            nums.len()
        )),
    }
}
/// Resolve the path the app will write to. It must be absolute — the app's
/// working directory differs from the client's.
fn resolve_output_path(output: Option<&str>) -> Result<String, String> {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let raw = match output {
        // `-` → a temp file the client streams to stdout, then deletes.
        Some("-") => std::env::temp_dir().join(format!(
            "infinify-screenshot-{}-{secs}.png",
            std::process::id()
        )),
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(format!("infinify-screenshot-{secs}.png")),
    };
    let abs = if raw.is_absolute() {
        raw
    } else {
        std::env::current_dir()
            .map_err(|e| format!("cannot resolve current directory: {e}"))?
            .join(raw)
    };
    Ok(abs.to_string_lossy().into_owned())
}

/// `args` are the arguments after `msg`. Returns the process exit status.
pub(crate) fn run(args: &[String]) -> i32 {
    match invoke(args) {
        Ok(()) => 0,
        Err(Stop::Help) => {
            print!("{USAGE}");
            0
        }
        Err(Stop::Usage(message)) => {
            eprintln!(
                "error: {message}\n\nFor the commands and their arguments: infinify msg --help"
            );
            2
        }
        Err(Stop::Failed(message)) => {
            eprintln!("error: {message}");
            1
        }
        Err(Stop::Reported) => 1,
    }
}
fn invoke(args: &[String]) -> Result<(), Stop> {
    let mut global = Global::default();
    // Options may precede the command: find where it starts, then parse them.
    let command_at = {
        let mut index = 0;
        loop {
            match args.get(index).map(String::as_str) {
                Some("--socket") => index += 2,
                Some(token) if token.starts_with('-') => index += 1,
                _ => break index.min(args.len()),
            }
        }
    };
    split(&args[..command_at], &[], &[], false, &mut global)?;
    let Some(command) = args.get(command_at) else {
        return usage("a command is required");
    };
    let invocation = to_invocation(command, &args[command_at + 1..], &mut global)?;
    let subscribe = invocation.request == Request::Subscribe;

    let path = match global.socket {
        Some(path) => path,
        None => match std::env::var_os("INFINIFY_SOCKET").filter(|path| !path.is_empty()) {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(
                std::env::var_os("HOME")
                    .ok_or_else(|| failed("HOME is not set — pass --socket <PATH>"))?,
            )
            .join("Library/Application Support/Infinify/infinify.sock"),
        },
    };
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| failed(format!("cannot connect to {}: {e}", path.display())))?;
    let mut payload = serde_json::to_vec(&invocation.request).map_err(failed)?;
    payload.push(b'\n');
    stream.write_all(&payload).map_err(failed)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(failed)?;
    if line.trim().is_empty() {
        return Err(failed("no response from Infinify"));
    }
    let reply: Reply =
        serde_json::from_str(line.trim_end()).map_err(|e| failed(format!("invalid reply: {e}")))?;
    let pretty = |reply: &Reply| serde_json::to_string_pretty(reply).map_err(failed);

    // `-o -` claims stdout for the PNG bytes, so it takes precedence over --json.
    // Clean up the temp file unconditionally, even if the read or write fails.
    if invocation.stdout_capture
        && let Ok(Response::Screenshot { path, .. }) = &reply
    {
        let bytes = std::fs::read(path);
        let _ = std::fs::remove_file(path);
        let bytes = bytes.map_err(|e| failed(format!("cannot read capture {path}: {e}")))?;
        return std::io::stdout().write_all(&bytes).map_err(failed);
    }
    // Subscribe switches to push mode: the first reply is just the ack, then the
    // server streams `Event` lines on the same connection until it closes.
    if subscribe {
        if global.json && reply.is_err() {
            // Same error surface as every other --json command.
            println!("{}", pretty(&reply)?);
            return Err(Stop::Reported);
        }
        reply.map_err(Stop::Failed)?;
        return stream_events(reader, global.json);
    }
    if global.json {
        println!("{}", pretty(&reply)?);
        // Exit non-zero on a command error too, so scripts can branch on it.
        return reply.map(|_| ()).map_err(|_| Stop::Reported);
    }
    print_response(reply.map_err(Stop::Failed)?);
    Ok(())
}
/// Read pushed `Event` lines until the server closes the connection, printing
/// each one (raw JSON with `--json`, else the human-readable block). Flushes
/// per event so a downstream pipe sees each snapshot promptly.
fn stream_events(mut reader: BufReader<UnixStream>, json: bool) -> Result<(), Stop> {
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).map_err(failed)? == 0 {
            return Ok(()); // server closed the connection
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            continue;
        }
        if json {
            println!("{trimmed}");
        } else {
            let Event::State(info) = serde_json::from_str::<Event>(trimmed).map_err(failed)?;
            print_state(&info);
            println!();
        }
        std::io::stdout().flush().map_err(failed)?;
    }
}
fn print_response(response: Response) {
    match response {
        Response::Camera { x, y } => println!("{x} {y}"),
        Response::Zoom(zoom) => println!("{zoom}"),
        Response::Layout(layout) => println!("{layout}"),
        Response::Focused(Some(w)) => {
            println!("#{} {}", w.id, w.app_id.as_deref().unwrap_or("(no app_id)"))
        }
        Response::Focused(None) => println!("(none)"),
        Response::Position { x, y } => println!("{x} {y}"),
        Response::Size { width, height } => println!("{width} {height}"),
        Response::Opacity(value) => println!("{value}"),
        Response::Pin(value) => println!("{value}"),
        Response::Bookmark { x, y } => println!("{x} {y}"),
        Response::Bookmarks(bookmarks) => {
            for (name, [x, y]) in bookmarks {
                println!("{name}: [{x}, {y}]");
            }
        }
        Response::Screenshot { path, .. } => println!("{path}"),
        Response::Ok => println!("ok"),
        Response::State(info) => print_state(&info),
        Response::DebugCounters(counters) => {
            for (key, value) in counters {
                println!("{key}: {value}");
            }
        }
    }
}
fn print_state(info: &StateInfo) {
    let titled = |title: &str| {
        if title.is_empty() {
            String::new()
        } else {
            format!("  \"{title}\"")
        }
    };
    println!("camera {} {}", info.camera.0, info.camera.1);
    println!("zoom {}", info.zoom);
    println!("layout {} ({})", info.layout, info.layout_short);
    println!("windows {}", info.windows.len());
    for w in &info.windows {
        let mark = if w.is_focused { "*" } else { " " };
        println!(
            "  {mark} #{} {} [{}, {}] {}x{}{}",
            w.id,
            w.app_id,
            w.position[0],
            w.position[1],
            w.size[0],
            w.size[1],
            titled(&w.title)
        );
    }
    println!("fullscreen {}", info.fullscreen.len());
    for f in &info.fullscreen {
        println!("  {} #{} {}{}", f.output, f.id, f.app_id, titled(&f.title));
    }
    println!("pinned {}", info.pinned.len());
    for p in &info.pinned {
        println!(
            "  {} #{} {} [{}, {}] {}x{}{}",
            p.output,
            p.id,
            p.app_id,
            p.position[0],
            p.position[1],
            p.size[0],
            p.size[1],
            titled(&p.title)
        );
    }
    println!("layers {}", info.layers.len());
    for ns in &info.layers {
        println!("    {ns}");
    }
    println!("canvas-layers {}", info.canvas_layers.len());
    for c in &info.canvas_layers {
        println!(
            "    {} [{}, {}] {}x{}",
            c.app_id, c.position[0], c.position[1], c.size[0], c.size[1]
        );
    }
    println!("outputs {}", info.outputs.len());
    for o in &info.outputs {
        let mark = if o.active { "*" } else { " " };
        println!(
            "  {mark} {} camera {} {} zoom {} {}x{}",
            o.name, o.camera.0, o.camera.1, o.zoom, o.size[0], o.size[1]
        );
    }
}
