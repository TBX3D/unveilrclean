# UnveilR

A dynamic analysis / deobfuscation tool for Roblox Luau scripts.

UnveilR runs an obfuscated script inside a heavily instrumented sandbox and
records every operation it performs, then re-emits those operations as clean,
readable Luau source code.

---

## How it works

```
 Obfuscated script
        │
        ▼
 1. Pre-process (cli.lua)
    ↳ Optionally inject CHECKIF / CHECKWHILE / CHECKOR / … call-sites
      into every conditional and loop so branch decisions are observable
      at runtime (--hookOp mode).
        │
        ▼
 2. Load & spy (hi.luau → Spy proxy)
    ↳ The script is loaded with loadstring and its _ENV is replaced by a
      fully-instrumented proxy table called `Locked`.  Every global access,
      method call, arithmetic operation, comparison, and loop iteration is
      intercepted and translated into a readable Luau source line.
        │
        ▼
 3. Emit (Beautify / Append)
    ↳ Each intercepted operation is serialised back to source via Beautify()
      and appended to an Output buffer.  Variable names are derived from the
      originating expression (e.g. GetService("Players") → `Players`).
        │
        ▼
 4. Post-process (minifier / varRenamer)
    ↳ Single-use variables are inlined, dead assignments are removed,
      and (optionally) auto-generated names are replaced with descriptive
      ones derived from their expression.
        │
        ▼
 5. Write result (out2.lua)
    ↳ The final cleaned string is written to the output file with a small
      metadata header showing the tool version and time taken.
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| [Lune](https://lune-org.github.io/docs) | Luau runtime used to execute `hi.luau` |
| `lua` (standard Lua 5.1/5.2 or LuaJIT) | Required only for the `--hookOp` pre-processing step |

Install Lune:

```sh
cargo install lune   # via Cargo
# or download a binary from https://github.com/lune-org/lune/releases
```

---

## Repository layout

```
unveilrclean/             (repository root)
├── hi.luau                    Main deobfuscation engine (entry point)
├── Libraries/
│   └── Types.luau             Known Roblox / executor global name lists
├── testing/
│   └── prom/
│       └── src/
│           ├── cli.lua        Text-based source pre-processor (hookOp unparser, Lune)
│           ├── unparser.luau  AST-based source re-emitter (new, Lune)
│           └── parser.luau    Luau recursive-descent parser used by unparser.luau
└── LICENSE
```

---

## Usage

```sh
lune hi.luau <obfuscated-script.lua> [options]
```

The deobfuscated output is written to `out2.lua` (or the path set by
`--outfile`).

### Options

| Flag | Default | Description |
|---|---|---|
| `--hookOp` | `true` | Inject CHECK* call-sites into every conditional before running. **Automatically disabled** for PureVM obfuscators (e.g. Luraph) that embed their own interpreter and do not call `loadstring`. Override with `--hookOp=false` to force-disable manually. |
| `--hookOpValue=spy\|<val>` | `spy` | Value spy proxies evaluate to inside hook-inserted expressions. |
| `--explore_funcs=<bool>` | `true` | Decompile nested functions recursively. |
| `--spy_exec_only=<bool>` | `true` | Only spy on known Roblox/executor globals; return nil for unknown names. |
| `--minifier=<bool>` | `true` | Inline single-use variables and remove dead assignments. |
| `--varRenamer=<bool>` | `false` | Replace `var<N>` names with expression-derived names. |
| `--raw=<bool>` | `false` | Skip the hookOp pre-processing step entirely. |
| `--max_ops=<number>` | `10500` | Hard cap on intercepted operations (prevents runaway scripts). |
| `--max_while_count=<number>` | `100000` | Separate cap for while-loop iterations. |
| `--max_bootstrap_seconds=<number>` | `0` (30 for PureVM) | Time limit in seconds for VM-obfuscated script execution. Automatically set to 30 s for PureVM scripts (no `loadstring`); 0 means unlimited. |
| `--saveFails=<bool>` | `false` | Write output after every operation (slow, but preserves partial results on crash). |
| `--env_index=<bool>` | `false` | Emit a comment line for every unknown global read. |
| `--outfile=<path>` | `out2.lua` | Path to write the deobfuscated output. |

### Examples

```sh
# Basic usage – deobfuscate a script with default settings
lune hi.luau myscript.lua

# Deobfuscate a Luraph-protected script (hookOp is auto-disabled for Luraph)
lune hi.luau myscript.luau

# Skip minification and write to a custom output file
lune hi.luau myscript.lua --minifier=false --outfile=cleaned.lua
```

---

### AST-based unparser (unparser.luau)

The new `testing/prom/src/unparser.luau` script is an AST-based alternative to `cli.lua`.
It parses the input file with `parser.luau` (a Luau recursive-descent parser bundled in
the same directory) and re-emits all statements with full hookOp instrumentation.

```sh
lune testing/prom/src/unparser.luau <input> <output> [<callId>] [<constantCollection>]
```

| Argument | Description |
|---|---|
| `<input>` | Path to the Lua/Luau source file to process. |
| `<output>` | Path where the instrumented output is written. |
| `<callId>` | Optional prefix string prepended to every CHECK*/CALL*/… call-site (default: none). Pass `"0"` for no prefix. |
| `<constantCollection>` | Pass `"1"` to enable constant-collection mode (wraps index accesses and string assignments with `GET(…)` / `CONSTRUCT(…)`). |

---

## Supported obfuscators

| Obfuscator | Status |
|---|---|
| Generic Luau obfuscation (constant encoding, name mangling) | ✅ Supported |
| MoonSec V3 (with anti-tamper) | ✅ Supported |
| MoonSec V3 (with constant protection) | ⚠️ Partial – constants may be missing from output |
| Luraph | ⚠️ Partial – hookOp is now **auto-disabled** for Luraph (PureVM detection); `debug.info` passes through; 30 s execution cap applied automatically. Roblox API calls made by the deobfuscated code are captured as spy output. Scripts whose deobfuscated payload contains an infinite game loop may need an OS-level timeout (`timeout 30 lune run hi.luau ...`). Full bytecode devirtualization is not yet implemented. |
| JayFuscator | ⚠️ WIP – output may trigger detection |

---

## License

MIT – see [LICENSE](LICENSE).
