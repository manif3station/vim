# Java and Perl support for classic Vim

This project installs a Java editing setup for **classic Vim**. The entry point
is [`cli/setup.pl`](cli/setup.pl); run it from any current
working directory. It locates its Perl modules and Vim assets relative to its
own path, then updates the invoking user's `.vimrc` and `.vim` directory. It
does not configure Neovim.

The setup uses coc.nvim with coc-java for Eclipse JDT Language Server features:
completion, diagnostics, navigation, rename, code actions, import organization,
Maven/Gradle project import, source navigation, and CodeLens. Perl buffers use
ALE for syntax checks and coc.nvim with PerlNavigator for completion,
diagnostics, and code navigation. If PerlNavigator is unavailable, an installed
Perl::LanguageServer remains a navigation/diagnostics fallback; its server does
not advertise completion support. The `gf` and `<C-w>gf` mappings resolve Perl
modules from the current project's `lib` directory first, then Perl's runtime
`@INC`. Perl syntax linting finds the nearest CPAN/Git root and adds its `lib`
directory without depending on Vim's current working directory. Vim plugins
provide the Darcula colorscheme, NERDTree file browser,
Airline status and buffer tabline, and Vimspector debugging when the installed
Vim has a Python 3 host.

## Requirements

- Classic Vim 9.0.0438 or newer, with `+job`, `+channel`, `+terminal`, and `+timers`.
- Perl 5.10 or newer (the installer and helpers use core modules only).
- PerlNavigator is optional; when installed, coc.nvim enables Perl completion,
  navigation, and diagnostics. On macOS, install it with `brew install
  perlnavigator`; alternatively install it locally with
  `npm install --prefix ~/.vim/tools/perlnavigator perlnavigator-server`.
- Perl::LanguageServer is supported as a diagnostics/navigation fallback, but
  it does not provide completion.
- Node.js 22.15.0 or newer, Git, and `curl` or `wget`.
- An installed and authenticated AI CLI: Copilot CLI by default, or Codex CLI or Claude Code as selected with `VIM_AI_WITH` in the project `.env`.
- Maven on `PATH`, or a Maven wrapper in each project, for Java test commands.
- A local JDK for building and testing. The installer detects `$JAVA_HOME` and
  SDKMAN candidates; pass `--jdk VERSION=PATH` for other installations.
- For debugging: a non-Windows Vim compiled with `+python3` and Python 3.10 or
  newer. Java debug support connects coc-java's Java Debug Server to Vimspector.

On supported platforms coc-java bundles a JRE for the language server. Local
project JDKs are still needed for Maven compilation and tests. Runtime settings
prefer Java 8 by default to match `hov1`, while preserving other detected JDKs.
JDK discovery checks `JAVA_HOME`, Java on `PATH`, then SDKMAN candidates.

## Install

```sh
perl cli/setup.pl --dry-run --show-config
perl cli/setup.pl
```

To install to a different home directory or supply a JDK explicitly:

```sh
perl cli/setup.pl --home /path/to/home --jdk 21=/opt/jdk-21
```

Install the published repository through Developer Dashboard by its Git
repository name:

```sh
d2 skill install vim
d2 vim.setup
```

Dashboard installs the remote repository under the `vim` skill name and uses
that name for its setup command.

The installer creates a timestamped backup before changing an existing `.vimrc`
and manages only the block between `vim-tools-java` markers. It installs the local
Vim plugin and helper modules into `.vim/after/plugin`, `.vim/bin`, and
`.vim/perl5`. Coc settings and extensions stay inside `.vim/coc` and
`.vim/coc-data`. It then runs vim-plug and installs `coc-java`, plus
`coc-java-debug` when debugger prerequisites are available.

## Keys and commands

Space is the leader key.

| Key/command | Action |
| --- | --- |
| `gd`, `gr`, `K` | Java definition, references, hover documentation |
| `gt`, `gT` | Next/previous tab (Vim defaults) |
| `gf`, `<C-w>gf` | Java definition or Perl module; open in current buffer/new tab |
| `<leader>rn`, `<leader>ca`, `<leader>oi` | Rename, code action, organize imports |
| `<leader>e` | Toggle NERDTree |
| `<leader>tt`, `<leader>tf` | Run nearest Java test or the current test class |
| `<leader>td` | Run nearest Java test suspended for debugger attach |
| `<leader>tc` | Find/open the related Java test source |
| `<leader>cv` | Display covered lines from the module's JaCoCo XML report |
| `F5` | Start Java application debugging when Vimspector support is installed |
| `:W`, `:X` | Command-line shortcuts: refuse on Coc errors; write and test / write and quit |

With Vim's clipboard support enabled, mouse/Visual selections and normal
yank/put operations use the host clipboard.

## AI assistant

The installer uses `VIM_AI_WITH` from `CODE/.env` to select the AI CLI. Choose
one value (`copilot`, `codex`, or `claude`); if the variable is absent, the
Copilot CLI is selected. A `VIM_AI_WITH` environment variable overrides the
`.env` value. The selected CLI must already be installed and authenticated.
For example:

```sh
VIM_AI_WITH=copilot
# or: VIM_AI_WITH=codex
# or: VIM_AI_WITH=claude
```

After a 1.2 second pause while typing in a filetype buffer, Vim requests an
automatic completion. Press `<C-x><C-a>` to request one immediately. Single-line
results appear as inline virtual text when Vim supports virtual text, otherwise
Vim shows a completion popup. Press `<C-y>` to accept an inline suggestion; use
`:AIDismiss` to clear it. `:AIComplete` makes the same request from Normal mode.
`:AIGenerate instruction` asks the selected CLI to replace
the current line; run it over a Visual selection to replace those lines.
`:AIAssistant [prompt]` opens the selected interactive CLI in a Vim terminal at
the current file's directory.

Completion prompts include the full in-memory current buffer, the cursor
position, and all other loaded file buffers, including unsaved edits. The
selected CLI runs from Vim's current working directory and can inspect relevant
project files for additional context. Copilot read/search tools remain enabled;
write and shell tools are disabled. Codex uses its read-only sandbox and Claude
uses plan mode. Generation requests include the selected source text. Vim
inserts generated text; the terminal assistant follows the selected CLI's
regular permissions and approval settings.

Java tests use the nearest Maven module and run `mvn -Dtest=Class[#method] test`
(or that module's `mvnw`). The helper reads the project's Java version from the
POM and selects a matching SDKMAN JDK when available. This mirrors the custom
Maven test flow on `hov1`. coc-java still imports Gradle projects for editing,
but these test commands currently require Maven. `:JavaCoverage` reads
`target/site/jacoco/jacoco.xml`; run the JaCoCo report goal in the project first.

For test debugging, `<leader>td` runs the selected Maven test with Surefire's
remote debug listener on port 5005. Merge
[`assets/vim/vimspector/java-test-attach.json`](assets/vim/vimspector/java-test-attach.json)
into the project's `.vimspector.json` once, then run
`:CocCommand java.debug.vimspector.start` after the test terminal reports that
the JVM is waiting. If the project already has a default Vimspector profile,
select **Java Test Attach** in its configuration picker. This leaves an existing
project debugger file untouched.

## Layout

- `cli/setup.pl`: runnable installer entry point.
- `lib/Vim/Tools/Java/`: JDK detection, Maven/project logic, coverage parsing, and
  installation code.
- `lib/Vim/Tools/AI/`: `.env` provider selection and default handling.
- `assets/vim/`: Vim plugin, installed command-line helper, and Vimspector test
  attach profile, plus the AI completion and assistant commands.
- `t/`: Perl unit tests (`prove -Ilib t`).
- `.env`: tracked project version (`VERSION`) and selected Vim AI CLI
  (`VIM_AI_WITH`). Increment `VERSION` when updating the installed Dashboard
  skill so setup commands use the current project files.

See [`VIM_WITH_JAVA.md`](VIM_WITH_JAVA.md) for the inspection notes on `hov1`.

Implementation references: [coc.nvim requirements and install](https://github.com/neoclide/coc.nvim/blob/release/doc/coc.txt),
[coc-java features and runtime settings](https://github.com/neoclide/coc-java),
[coc-java-debug integration](https://cocnvim.com/extensions/coc-java-debug), and
[Vimspector requirements](https://github.com/puremourning/vimspector). Maven
test debugging uses [Surefire's remote debugging option](https://maven.apache.org/surefire/maven-surefire-plugin/examples/debugging.html).
