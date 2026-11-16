#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Production native module descriptions, visibility checks and incremental archives."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/native-modules.json"
CACHE = ROOT / "target/native-modules"
IMPORT = re.compile(r'^\s*#\s*(?:import|include)\s*([<"])([^">]+)[">]', re.M)


def run(argv):
    subprocess.run([str(x) for x in argv], cwd=ROOT, check=True)


def digest(path):
    path = Path(path)
    stat = path.stat()
    return [stat.st_mtime_ns, stat.st_size, hashlib.sha256(path.read_bytes()).hexdigest()]


def load():
    data = json.loads(MANIFEST.read_text())
    if data["schema"] != 1:
        raise ValueError("unsupported native module schema")
    return data


def closure(modules, roots):
    result = []
    def visit(name):
        if name in result:
            return
        result.append(name)
        for dep in modules[name]["dependencies"]:
            visit(dep)
    for name in roots:
        visit(name)
    return result


def visibility(data):
    """Check direct edges, even though exported headers need transitive -I paths."""
    modules = data["modules"]
    owners = {}
    by_name = {}
    for name, module in modules.items():
        directory = ROOT / module["path"]
        public = set(module["public_headers"])
        public_directory = directory / module["public"]
        actual = {p.name for p in public_directory.glob("*.h")}
        if actual != public:
            raise ValueError(f"{name}: public header list differs from directory: {actual ^ public}")
        for path in directory.rglob("*"):
            if path.suffix not in (".h", ".m", ".c"):
                continue
            relative = path.relative_to(ROOT).as_posix()
            owners[relative] = (name, path.parent == public_directory and path.name in public)
            if path.name in by_name:
                raise ValueError(f"ambiguous native filename: {path.name}")
            by_name[path.name] = relative
        declared = {s["path"] for s in module["sources"]}
        # Payload .m fragments are textual includes, never independent inputs.
        fragments = set(module.get("fragments", []))
        actual_sources = {p.name for p in directory.iterdir() if p.suffix in (".m", ".c")}
        if declared | fragments != actual_sources or declared & fragments:
            raise ValueError(f"{name}: source list differs from directory: {(declared | fragments) ^ actual_sources}")
    entry = data["products"]["app"]["entry"]
    owners[entry["path"]] = ("app-entry", False)
    for relative, (owner, _) in owners.items():
        deps = entry["dependencies"] if owner == "app-entry" else modules[owner]["dependencies"]
        for match in IMPORT.finditer((ROOT / relative).read_text()):
            delimiter, spelling = match.groups()
            target = by_name.get(Path(spelling).name)
            if target:
                target_owner, public = owners[target]
                line = (ROOT / relative).read_text()[:match.start()].count("\n") + 1
                if spelling != Path(spelling).name:
                    raise ValueError(f"{relative}:{line}: use a bare native import, not {spelling}")
                if target_owner != owner and (target_owner not in deps or not public):
                    raise ValueError(f"{relative}:{line}: {spelling} is private or its module {target_owner} is undeclared")
                if owner != "app-entry" and relative.endswith(".h") and owners[relative][1] and target_owner == owner and not public:
                    raise ValueError(f"{relative}:{line}: public header imports private {spelling}")
            elif delimiter == '"' and spelling == "driftwm_desktop.h":
                includes = entry.get("include_dirs", []) if owner == "app-entry" else modules[owner].get("include_dirs", [])
                if "crates/desktop/src" not in includes:
                    raise ValueError(f"{relative}: Rust C header is not declared for {owner}")
            elif delimiter == '"' and Path(spelling).suffix in (".h", ".m", ".c"):
                raise ValueError(f"{relative}: unknown project import {spelling}")


def include_flags(data, names, private=False):
    modules = data["modules"]
    flags = []
    if private:
        # Only the compilation owner, never the owner's dependencies.
        for name in names:
            flags.append("-I" + modules[name]["path"] + "/" + modules[name]["private"])
    for name in closure(modules, names):
        flags.append("-I" + str(Path(modules[name]["path"]) / modules[name]["public"]))
    # Non-native includes are private to the compilation owner.
    for name in names:
        flags.extend("-I" + path for path in modules[name].get("include_dirs", []))
    return list(dict.fromkeys(flags))


def source_records(data, product, selected=None):
    result = []
    for name, module in data["modules"].items():
        if selected is not None and name not in selected:
            continue
        for source in module["sources"]:
            if product in source["products"] and not (selected is not None and source.get("entry")):
                result.append((name, module["path"] + "/" + source["path"], source.get("entry", False)))
    if selected is None and "entry" in data["products"][product]:
        result.append(("app-entry", data["products"][product]["entry"]["path"], True))
    return result


def flags(data, product, arch, source, owner, defines):
    profile = data["products"][product]
    args = ["-O2", "-arch", arch, "-mmacosx-version-min=26.0"]
    if source.endswith(".c"):
        args += ["-std=gnu11"]
    elif profile["arc"]:
        args += ["-fobjc-arc"]
    args += ["-Wall", "-Wextra", "-Werror"]
    names = profile["entry"]["dependencies"] if owner == "app-entry" else [owner]
    includes = include_flags(data, names, private=owner != "app-entry")
    if owner == "app-entry":
        includes = [flag for flag in includes if flag != "-Icrates/desktop/src"]
        includes += ["-I" + path for path in profile["entry"].get("include_dirs", [])]
    args += includes
    args += ["-D" + item for item in defines]
    return args


def read_json(path, fallback=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def atomic_json(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, sort_keys=True))
    os.replace(temp, path)


def dependencies(path):
    # clang depfiles escape spaces and continue lines with backslash-newline.
    text = path.read_text().replace("\\\n", "")
    return [str((ROOT / p).resolve()) for p in shlex.split(text.split(": ", 1)[1])]


def compiler_identity():
    compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    return [compiler, subprocess.check_output([compiler, "--version"], text=True),
            subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
            {key: os.environ.get(key) for key in ("SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS",
             "CPATH", "C_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "SOURCE_DATE_EPOCH")}]


def build(data, product, arch, defines, module=None):
    visibility(data)
    selected = closure(data["modules"], [module]) if module else None
    records = source_records(data, product, selected)
    profile_dir = CACHE / product / arch
    # Defines select separate caches (daemon pins are inputs, not output paths).
    if defines:
        profile_dir /= hashlib.sha256(json.dumps(defines).encode()).hexdigest()[:16]
    profile_dir.mkdir(parents=True, exist_ok=True)
    compiler = compiler_identity()
    jobs = int(os.environ.get("INFINIFY_NATIVE_JOBS", "2"))
    if jobs < 1:
        raise ValueError("INFINIFY_NATIVE_JOBS must be positive")
    entries = []
    objects = {}
    dirty = []
    object_keys = {}
    for owner, source, entry in records:
        directory = profile_dir / owner
        directory.mkdir(exist_ok=True)
        obj = directory / (Path(source).name + ".o")
        metadata = obj.with_suffix(".json")
        command = ["xcrun", "clang"] + flags(data, product, arch, source, owner, defines)
        command += ["-MMD", "-MF", str(obj.with_suffix(".d")), "-c", source, "-o", str(obj)]
        previous = read_json(metadata, {})
        deps = previous.get("dependencies", [str(ROOT / source)])
        try:
            stamps = {p: digest(p) for p in deps}
        except OSError:
            stamps = {}
        current = {"command": command, "compiler": compiler, "stamps": stamps}
        changed = not obj.exists() or not stamps or previous.get("inputs") != current
        if changed:
            dirty.append((owner, source, obj, metadata, command, compiler))
        object_keys[str(obj)] = current
        if entry:
            entries.append(obj)
        else:
            objects.setdefault(owner, []).append(obj)
    # Invalidate before compiling, so failed builds cannot publish an old archive.
    for owner, *_ in dirty:
        (profile_dir / owner / "module.a").unlink(missing_ok=True)
        (profile_dir / owner / "archive.json").unlink(missing_ok=True)

    def compile_one(task):
        owner, source, obj, metadata, command, compiler = task
        obj.unlink(missing_ok=True)
        metadata.unlink(missing_ok=True)
        depfile = obj.with_suffix(".d")
        temp = obj.with_suffix(".o.tmp")
        argv = command[:-1] + [str(temp)]
        print(f"native compile {product}/{arch} {source}", file=sys.stderr, flush=True)
        try:
            run(argv)
            deps = dependencies(depfile)
            stamps = {p: digest(p) for p in deps}
            os.replace(temp, obj)
            value = {"command": command, "compiler": compiler, "stamps": stamps}
            atomic_json(metadata, {"dependencies": deps, "inputs": value})
            object_keys[str(obj)] = value
        finally:
            temp.unlink(missing_ok=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        # Executor waits for outstanding jobs on failure; no link proceeds.
        list(pool.map(compile_one, dirty))
    archives = {}
    for owner, group in objects.items():
        archive = profile_dir / owner / "module.a"
        stamp = archive.with_name("archive.json")
        inputs = [{"object": str(p), "inputs": object_keys[str(p)]} for p in group]
        if not archive.exists() or read_json(stamp) != inputs:
            archive.unlink(missing_ok=True)
            stamp.unlink(missing_ok=True)
            temp = archive.with_suffix(".a.tmp")
            print(f"native archive {product}/{arch} {owner}", file=sys.stderr, flush=True)
            try:
                run(["xcrun", "libtool", "-static", "-o", temp] + group)
                os.replace(temp, archive)
                atomic_json(stamp, inputs)
            finally:
                temp.unlink(missing_ok=True)
        archives[owner] = archive
    # Forget archives whose source list is now empty.
    expected = set(objects)
    for directory in profile_dir.iterdir():
        if directory.is_dir() and directory.name in data["modules"] and directory.name not in expected:
            (directory / "module.a").unlink(missing_ok=True)
            (directory / "archive.json").unlink(missing_ok=True)
    return archives, entries


def link_flags(archives, module=None, dependency_mode="force"):
    result = []
    if module and module in archives:
        result.append("-Wl,-force_load," + str(archives[module]))
    for name, path in archives.items():
        if name == module:
            continue
        result.append("-Wl,-force_load," + str(path) if dependency_mode == "force" else str(path))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["validate", "clean", "legacy-includes", "cflags", "ldflags", "module", "build"])
    parser.add_argument("product", nargs="?", default="app")
    parser.add_argument("module", nargs="?")
    parser.add_argument("--arch")
    parser.add_argument("--output")
    parser.add_argument("--define", action="append", default=[])
    parser.add_argument("--dependencies", choices=["normal", "force"], default="normal")
    args = parser.parse_args()
    os.chdir(ROOT)
    data = load()
    if args.action == "validate":
        visibility(data)
        return
    if args.action == "legacy-includes":
        names = list(data["modules"])
        if args.product == "helper":
            names = ["app-Support"] + [n for n in names if n.startswith("dock-helper-")]
        paths = []
        if args.product != "helper":
            paths += ["-Icrates/desktop/src", "-Inative/app"]
        for name in names:
            module = data["modules"][name]
            paths += ["-I" + module["path"], "-I" + module["path"] + "/" + module["private"]]
        print(shlex.join(paths))
        return
    if args.action == "cflags":
        if not args.module:
            parser.error("cflags needs PRODUCT MODULE")
        print(shlex.join(include_flags(data, [args.module])))
        return
    if args.action == "clean":
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        with (CACHE.parent / ".native-modules.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            shutil.rmtree(CACHE, ignore_errors=True)
        return
    arch = args.arch or data["products"][args.product]["arch"]
    if args.action in ("module", "ldflags") and not args.module:
        parser.error("module and ldflags need PRODUCT MODULE")
    CACHE.mkdir(parents=True, exist_ok=True)
    # Serializes shared cache writers; compilation inside one invocation is bounded.
    with (CACHE.parent / ".native-modules.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        archives, entries = build(data, args.product, arch, args.define, args.module)
        if args.action in ("module", "ldflags"):
            print(shlex.join(link_flags(archives, args.module, args.dependencies)))
            return
        if not args.output:
            parser.error("build needs --output")
        profile = data["products"][args.product]
        if profile.get("object"):
            paths = source_records(data, args.product)
            owner, source, _ = paths[0]
            shutil.copy2(archives[owner].parent / (Path(source).name + ".o"), args.output)
            return
        command = ["xcrun", "clang", "-O2", "-arch", arch, "-mmacosx-version-min=26.0"]
        if profile["arc"]:
            command += ["-fobjc-arc"]
        command += ["-Wall", "-Wextra", "-Werror"]
        if profile.get("dynamic"):
            command += ["-dynamiclib", f"-Wl,-install_name,@rpath/payload-{arch}.dylib"]
        command += [str(p) for p in entries] + link_flags(archives)
        command += profile.get("libraries", [])
        for framework in profile["frameworks"]:
            command += ["-framework", framework]
        command += ["-o", args.output]
        run(command)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"native-modules: {error}", file=sys.stderr)
        sys.exit(1)
