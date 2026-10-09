// SPDX-License-Identifier: GPL-3.0-or-later
mod scenario;

use std::{env, path::PathBuf, process::ExitCode};

use anyhow::{Context, Result, bail};
use serde::Serialize;

const HELP: &str = "driftwm — macOS canvas development tools\n\n\
Usage:\n  driftwm doctor [--json]\n  driftwm windows [--json]\n  driftwm scenario <file.json> [--state-dir <directory>] [--json]\n  driftwm scene <file.json> [--state-dir <directory>] [--json]\n  driftwm fixture-probe [--json]\n\n\
Doctor and windows are read-only. Scenario replay changes saved canvas data only.\n\
Fixture-probe launches and transforms only the bundled native fixture.\n\
This build is a development foundation, not a complete desktop window manager.";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("driftwm: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() || matches!(args[0].as_str(), "--help" | "-h" | "help") {
        println!("{HELP}");
        return Ok(());
    }
    if args[0] == "--version" {
        println!("driftwm {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let command = args.remove(0);
    let json = if let Some(index) = args.iter().position(|arg| arg == "--json") {
        args.remove(index);
        true
    } else {
        false
    };
    match command.as_str() {
        "doctor" => {
            no_args(&args)?;
            print_report(&driftwm_macos_backend::doctor()?, json)?;
        }
        "windows" => {
            no_args(&args)?;
            print_report(&driftwm_macos_backend::list_windows()?, json)?;
        }
        "fixture-probe" => {
            no_args(&args)?;
            print_report(&driftwm_macos_backend::probe_fixture()?, json)?;
        }
        "scenario" | "scene" => {
            let mut state_dir = None;
            if let Some(index) = args.iter().position(|arg| arg == "--state-dir") {
                let value = args
                    .get(index + 1)
                    .context("--state-dir requires a directory")?;
                state_dir = Some(PathBuf::from(value));
                args.drain(index..=index + 1);
            }
            if args.len() != 1 {
                bail!("scenario requires exactly one file path; see --help");
            }
            let report = scenario::replay(&PathBuf::from(&args[0]), state_dir.as_deref())?;
            print_report(&report, json)?;
        }
        _ => bail!("unknown command {command:?}; see --help"),
    }
    Ok(())
}

fn no_args(args: &[String]) -> Result<()> {
    if !args.is_empty() {
        bail!("unexpected arguments: {}", args.join(" "));
    }
    Ok(())
}

fn print_report(report: &impl Serialize, json: bool) -> Result<()> {
    if !json {
        println!("Evidence report (use --json for machine-readable output):");
    }
    println!("{}", serde_json::to_string_pretty(report)?);
    Ok(())
}
