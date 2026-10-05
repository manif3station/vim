use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use Vim::Tools::Java::Installer;
use lib 'lib';
use Vim::Tools::Java::Installer qw(render_vimrc);

my $vimrc = render_vimrc(
    vim_home => '/home/test/.vim',
    jdks => [ { major => 8, home => '/jdk/8' }, { major => 21, home => '/jdk/21' } ],
    debugger => 1,
);
like($vimrc, qr/" >>> vim-tools-java BEGIN/, 'managed config block has a start marker');
like($vimrc, qr/" <<< vim-tools-java END/, 'managed config block has an end marker');
like($vimrc, qr/Plug 'neoclide\/coc\.nvim', \{'branch': 'release'\}/, 'classic Vim coc plugin is declared');
like($vimrc, qr/if empty\(\$TMUX\).*clipboard=unnamedplus,autoselect.*clipboard=autoselectplus.*set clipboard=/s, 'Vim copies Visual selections to the host in tmux without aliasing yy/p');
like($vimrc, qr/autocmd FileType java,perl setlocal expandtab tabstop=4 shiftwidth=4 softtabstop=4/, 'Java and Perl use four spaces');
like($vimrc, qr/autocmd FileType javascript,javascriptreact,typescript,typescriptreact,css,xml,html,xhtml,yaml setlocal expandtab tabstop=2 shiftwidth=2 softtabstop=2/, 'JavaScript, CSS, XML, HTML, and YAML use two spaces');
SKIP: {
    my $vim = `command -v vim 2>/dev/null`;
    chomp $vim;
    skip 'Vim editor settings integration requires classic Vim on Unix-like systems', 7
        unless $vim && $^O ne 'MSWin32';
    my ($clipboard_config) = $vimrc =~ /(^if has\('clipboard'\)\n.*?^endif$)/ms;
    ok(defined $clipboard_config, 'installer renders a complete clipboard configuration block');
    my ($indent_config) = $vimrc =~ /(augroup vim_tools_indentation\n.*?augroup END)/s;
    ok(defined $indent_config, 'installer renders filetype-specific indentation rules');
    my $clipboard_home = tempdir(CLEANUP => 1);
    my $script = File::Spec->catfile($clipboard_home, 'clipboard.vim');
    my $result = File::Spec->catfile($clipboard_home, 'clipboard-result.txt');
    my $clipboard_state = File::Spec->catfile($clipboard_home, 'clipboard-state.txt');
    my $indent_result = File::Spec->catfile($clipboard_home, 'indent-result.txt');
    my $vim_log = File::Spec->catfile($clipboard_home, 'clipboard-vim.log');
    my $clipboard_plugin = abs_path(File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'clipboard.vim'));
    open my $script_fh, '>', $script or die "Cannot write Vim clipboard fixture: $!";
    print {$script_fh} "if has('clipboard') | set clipboard=unnamedplus | endif\n";
    print {$script_fh} "$clipboard_config\n";
    print {$script_fh} "filetype plugin indent on\n$indent_config\n";
    print {$script_fh} "source $clipboard_plugin\n";
    print {$script_fh} "let g:indent_results = []\n";
    print {$script_fh} "for ft in ['java', 'perl', 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'css', 'xml', 'html', 'xhtml', 'yaml']\n";
    print {$script_fh} "  setlocal filetype=\n  execute 'setfiletype ' . ft\n";
    print {$script_fh} "  call add(g:indent_results, printf('%s:%d:%d:%d:%d', &l:filetype, &l:tabstop, &l:shiftwidth, &l:softtabstop, &l:expandtab))\nendfor\n";
    print {$script_fh} "call writefile(g:indent_results, " . vim_string($indent_result) . ")\n";
    print {$script_fh} "call writefile([string(has('clipboard')), string(has('patch-9.1.0000')), &clipboard, maparg('<C-c>', 'n'), maparg('<C-c>', 'x'), maparg('<C-v>', 'n'), maparg('<C-v>', 'i')], " . vim_string($clipboard_state) . ")\n";
    print {$script_fh} "call setline(1, ['first line', 'second line'])\n";
    print {$script_fh} "normal! gg\nnormal! yy\nnormal! j\nnormal! p\n";
    print {$script_fh} "call writefile(getline(1, '\$'), " . vim_string($result) . ")\nqa!\n";
    close $script_fh;
    local $ENV{TMUX} = 'vim-test-session';
    my $status = system($vim, '-Nu', 'NONE', '-n', '-i', 'NONE', '-es', "-V1$vim_log", '-S', $script);
    if ($status != 0 && -f $vim_log) {
        open my $log_fh, '<', $vim_log or die "Cannot read Vim clipboard log: $!";
        diag(do { local $/; <$log_fh> // '' });
        close $log_fh;
    }
    is($status, 0, 'Vim executes the generated clipboard configuration in tmux mode');
    open my $indent_fh, '<', $indent_result or die "No Vim indentation output: $!";
    my @indent_lines = <$indent_fh>;
    close $indent_fh;
    chomp @indent_lines;
    is_deeply(\@indent_lines, [
        'java:4:4:4:1', 'perl:4:4:4:1',
        'javascript:2:2:2:1', 'javascriptreact:2:2:2:1',
        'typescript:2:2:2:1', 'typescriptreact:2:2:2:1',
        'css:2:2:2:1', 'xml:2:2:2:1', 'html:2:2:2:1', 'xhtml:2:2:2:1', 'yaml:2:2:2:1',
    ], 'Vim applies four-space Java/Perl and two-space web/YAML indentation');
    open my $clipboard_state_fh, '<', $clipboard_state or die "No Vim clipboard state: $!";
    my @clipboard_state_lines = <$clipboard_state_fh>;
    close $clipboard_state_fh;
    chomp @clipboard_state_lines;
    is($clipboard_state_lines[2], $clipboard_state_lines[0] eq '1' && $clipboard_state_lines[1] eq '1' ? 'autoselectplus' : '',
        'tmux Visual selection copying does not alias the unnamed yank register');
    is_deeply([@clipboard_state_lines[3..6]], ['"+yy', '"+y', '"+p', '<C-R>+'],
        'Ctrl-C/Ctrl-V maps copy and paste using the host clipboard');
    open my $result_fh, '<', $result or die "No Vim clipboard output: $!";
    my @lines = <$result_fh>;
    close $result_fh;
    chomp @lines;
    is_deeply(\@lines, ['first line', 'second line', 'first line'],
        'yy followed by p yanks and pastes a line inside tmux');

    SKIP: {
        my $tmux = `command -v tmux 2>/dev/null`;
        chomp $tmux;
        my $vim_features = `$vim --version 2>/dev/null`;
        skip 'mouse copy/paste integration requires tmux and Vim +clipboard_provider', 3
            unless $tmux && $vim_features =~ /\+clipboard_provider/;
        my $copy_file = File::Spec->catfile($clipboard_home, 'mouse-copy.txt');
        my $mouse_file = File::Spec->catfile($clipboard_home, 'mouse-selection.txt');
        my $mouse_script = File::Spec->catfile($clipboard_home, 'mouse-clipboard.vim');
        open my $mouse_source, '>', $mouse_file or die "Cannot write mouse clipboard fixture: $!";
        print {$mouse_source} "alpha\nbeta\n";
        close $mouse_source;
        open my $mouse_vim, '>', $mouse_script or die "Cannot write mouse clipboard Vim script: $!";
        print {$mouse_vim} "function! VimToolsTestCopy(reg, type, lines) abort\n";
        print {$mouse_vim} "  call writefile(a:lines, " . vim_string($copy_file) . ")\nendfunction\n";
        print {$mouse_vim} "function! VimToolsTestPaste(reg) abort\n";
        print {$mouse_vim} "  return ['v', readfile(" . vim_string($copy_file) . ")]\nendfunction\n";
        print {$mouse_vim} "let v:clipproviders['vimtools_test'] = {'copy': {'+': function('VimToolsTestCopy')}, 'paste': {'+': function('VimToolsTestPaste')}}\n";
        print {$mouse_vim} "set mouse=a clipboard=autoselectplus clipmethod=vimtools_test\n";
        print {$mouse_vim} "execute 'source ' . fnameescape(" . vim_string(abs_path(File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'clipboard.vim'))) . ")\n";
        close $mouse_vim;
        my $session = "vim-clipboard-$$";
        my $mouse_status = system($tmux, 'new-session', '-d', '-s', $session, '-x', '100', '-y', '30',
            $vim, '-Nu', 'NONE', '-n', '-i', 'NONE', $mouse_file, '-S', $mouse_script);
        is($mouse_status, 0, 'clipboard shortcut integration starts in a Vim terminal');
        if ($mouse_status != 0) {
            skip 'Vim clipboard integration session could not start', 2;
        } else {
            select undef, undef, undef, 1;
            system($tmux, 'send-keys', '-t', "$session:0.0", 'v', 'l', 'C-c', 'j', 'C-v');
            select undef, undef, undef, 0.5;
            system($tmux, 'send-keys', '-t', "$session:0.0", 'Escape', ':wq', 'Enter');
            for (1 .. 20) {
                last if system("$tmux has-session -t $session >/dev/null 2>&1") != 0;
                select undef, undef, undef, 0.1;
            }
            open my $copied, '<', $copy_file or die "Visual Ctrl-C did not write to the clipboard provider: $!";
            my @copied = <$copied>;
            close $copied;
            is_deeply(\@copied, ["al\n"], 'Ctrl-C copies a mouse-style Visual selection');
            open my $mouse_result, '<', $mouse_file or die "Cannot read mouse copy/paste fixture: $!";
            my @mouse_lines = <$mouse_result>;
            close $mouse_result;
            chomp @mouse_lines;
            is_deeply(\@mouse_lines, ['alpha', 'baleta'], 'Ctrl-V pastes the selected text at the cursor');
            system("$tmux kill-session -t $session >/dev/null 2>&1");
        }
    }
}
open my $navigation_asset, '<', File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'java-tools.vim') or die $!;
my $navigation = do { local $/; <$navigation_asset> };
close $navigation_asset;
like($navigation, qr/nnoremap <silent> gt :bnext<CR>/, 'gt moves to the next tabline buffer');
like($navigation, qr/nnoremap <silent> gT :bprevious<CR>/, 'gT moves to the previous tabline buffer');
like($navigation, qr/function! s:JavaProjectSource\(class_name\)/, 'Java navigation searches project source roots');
like($navigation, qr/function! s:JavaMavenSource\(class_name\)/, 'Java navigation searches Maven source JARs');
like($navigation, qr/return 'zipfile:\/\/' \. l:jar \. '::' \. l:relative/, 'Maven sources open through Vim ZIP support');
like($vimrc, qr/if !exists\('g:plugs'\)/, 'managed block reuses an existing vim-plug session');
like($vimrc, qr/Plug 'dense-analysis\/ale'/, 'Perl linting plugin is declared');
like($vimrc, qr/Plug 'vim-perl\/vim-perl'/, 'Perl syntax plugin is declared');
like($vimrc, qr/Plug 'puremourning\/vimspector'/, 'debugger plugin is conditional on detected support');
like($vimrc, qr/vim_tools_ai_provider = 'copilot'/, 'Copilot CLI is rendered as the default AI provider');
like($vimrc, qr/ale_linters = \{'perl': \['perl'\]\}/, 'Perl syntax checks are enabled by default');
like($vimrc, qr/function! s:PerlProjectRoot\(path\)/, 'Perl linting locates the project root from the buffer path');
like($vimrc, qr/autocmd FileType perl call s:ConfigurePerlLintOptions\(\)/, 'Perl linting uses the buffer project lib independently of Vim cwd');
like($vimrc, qr{/home/test/\.vim/tools/perlnavigator/node_modules/\.bin/perlnavigator}, 'local PerlNavigator install path is generated without wildcard expansion');
like($vimrc, qr/coc_user_config\.languageserver\['perlnavigator'\]/, 'PerlNavigator is configured as a Coc language server');
like($vimrc, qr/let g:coc_user_config\.languageserver\['perllanguageserver'\]/, 'Perl::LanguageServer remains a navigation fallback');
like($vimrc, qr/call remove\(g:coc_user_config\.languageserver, 'perlnavigator'\)/, 'stale PerlNavigator entries are cleared before server selection');
like($vimrc, qr/call remove\(g:coc_user_config\.languageserver, 'perllanguageserver'\)/, 'stale Perl::LanguageServer entries are cleared before server selection');
like($vimrc, qr/call system\('perl -MPerl::LanguageServer -e 1 2>\/dev\/null'\)/, 'Perl::LanguageServer availability is probed at Vim startup');
like($vimrc, qr/let g:vim_tools_perllanguageserver_available = v:shell_error == 0/, 'Perl::LanguageServer fallback checks the process exit status');
unlike($vimrc, qr/ale_linters\.perl \+= \['languageserver'\]/, 'Perl LSP diagnostics do not run twice through ALE and Coc');
like($vimrc, qr/vim_tools_perl_completion/, 'Perl completion uses Coc only when PerlNavigator is available');
like($vimrc, qr/coc#refresh\(\).*C-n/, 'completion uses Coc for Java with Vim keyword fallback');
like($vimrc, qr/autocmd FileType perl inoremap <buffer><silent><expr> <C-Space> coc#refresh\(\)/, 'Perl completion maps Ctrl-Space to Coc when PerlNavigator is present');
like($vimrc, qr/JavaSE-1\.8/, 'Java 8 project runtime is represented');
like($vimrc, qr/java\.configuration\.runtimes/, 'Coc Java receives local JDK configuration');
like($vimrc, qr/JavaTestNearest/, 'custom Java test workflow is mapped');
like($vimrc, qr/JavaDebugTestNearest/, 'nearest test debugging workflow is mapped');
unlike($vimrc, qr/init\.lua|nvim-jdtls|nvim-dap/, 'generated config has no Neovim setup');
my $without_debugger = render_vimrc(vim_home => '/home/test/.vim', jdks => [], debugger => 0);
unlike($without_debugger, qr/Plug 'puremourning\/vimspector'/, 'Vimspector is omitted when host prerequisites are missing');
like($without_debugger, qr/vim_tools_java_debugger_enabled = 0/, 'the Vim helper disables test debugging when Vimspector is unavailable');
my $codex_config = render_vimrc(vim_home => '/home/test/.vim', jdks => [], debugger => 0, ai_provider => 'codex');
like($codex_config, qr/vim_tools_ai_provider = 'codex'/, 'selected CLI is written into the managed Vim configuration');

open my $ai_asset, '<', File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'ai-tools.vim') or die $!;
my $ai_plugin = do { local $/; <$ai_asset> };
close $ai_asset;
like($ai_plugin, qr/inoremap <silent> <C-x><C-a>/, 'AI completion has an Insert-mode mapping');
like($ai_plugin, qr/timer_start\(1200/, 'AI completion starts automatically after a typing pause');
like($ai_plugin, qr/prop_add\(line\('\.'\), col\('\.'\), \{'type': 'VimToolsAICompletion', 'text': l:lines\[0\]\}\)/, 'AI suggestions render inline as Vim text properties');
like($ai_plugin, qr/'text_align': 'below'/, 'multi-line AI suggestions render below the cursor line');
like($ai_plugin, qr/VimToolsAIAcceptTab\(\)/, 'Tab accepts AI text and delegates to its prior mapping otherwise');
like($ai_plugin, qr/command! -range -nargs=\* AIGenerate/, 'AI generation supports replacing a Visual selection');
like($ai_plugin, qr/'--sandbox', 'read-only'/, 'Codex completion runs in its read-only CLI sandbox');
like($ai_plugin, qr/'--permission-mode', 'plan'/, 'Claude completion uses its non-editing plan mode');
like($ai_plugin, qr/'--silent'/, 'Copilot completion suppresses progress output');

my $tmp = tempdir(CLEANUP => 1);
my $config_path = File::Spec->catfile($tmp, '.vimrc');
open my $config, '>', $config_path or die $!;
print {$config} "set nowrap\n";
close $config;
my $installer = Vim::Tools::Java::Installer->new(root => '.', home => $tmp, vimrc => $config_path);
$installer->_install_assets;
ok(-f File::Spec->catfile($tmp, '.vim', 'after', 'plugin', 'ai-tools.vim'), 'AI Vim plugin asset is installed');
ok(-f File::Spec->catfile($tmp, '.vim', 'after', 'plugin', 'clipboard.vim'), 'clipboard shortcuts are installed');
ok(-f File::Spec->catfile($tmp, '.vim', 'perl5', 'Vim', 'Tools', 'Java', 'Jdk.pm'), 'renamed Java modules are installed under the new namespace');
ok(-f File::Spec->catfile($tmp, '.vim', 'perl5', 'Vim', 'Tools', 'Perl', 'ModuleLookup.pm'), 'renamed Perl helpers are installed under the new namespace');
$installer->_write_vimrc($vimrc);
open my $written, '<', $config_path or die $!;
my $first = do { local $/; <$written> };
close $written;
like($first, qr/^set nowrap\n/s, 'existing user Vim settings are preserved');
like($first, qr/" >>> vim-tools-java BEGIN/, 'managed Vim block is installed');
ok((glob "$config_path.bak.*"), 'existing Vim config is backed up');
$installer->_write_vimrc($vimrc);
open my $again, '<', $config_path or die $!;
my $second = do { local $/; <$again> };
close $again;
is(() = $second =~ /" >>> vim-tools-java BEGIN/g, 1, 'reinstall replaces rather than duplicates the managed block');

my $broken_path = File::Spec->catfile($tmp, 'broken.vimrc');
open my $broken, '>', $broken_path or die $!;
print {$broken} "\" >>> vim-tools-java BEGIN\n";
close $broken;
my $broken_installer = Vim::Tools::Java::Installer->new(root => '.', home => $tmp, vimrc => $broken_path);
my $ok = eval { $broken_installer->_write_vimrc($vimrc); 1 };
ok(!$ok && $@ =~ /Incomplete vim-tools-java markers/, 'incomplete managed blocks fail without replacing user config');

my $tool_home = tempdir(CLEANUP => 1);
my $tool_bin = File::Spec->catdir($tool_home, 'bin');
make_path($tool_bin);
write_executable(File::Spec->catfile($tool_bin, 'vim'), <<'SH');
#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'VIM - Vi IMproved 9.2 +python3\n'
fi
if [ -n "$VIM_TEST_LOG" ]; then printf '%s\n' "$*" >> "$VIM_TEST_LOG"; fi
exit 0
SH
write_executable(File::Spec->catfile($tool_bin, 'node'), "#!/bin/sh\nprintf 'v22.15.0\n'\n");
write_executable(File::Spec->catfile($tool_bin, 'python3'), "#!/bin/sh\nprintf 'Python 3.12.1\n'\n");
write_executable(File::Spec->catfile($tool_bin, 'git'), "#!/bin/sh\nexit 0\n");
write_executable(File::Spec->catfile($tool_bin, 'copilot'), "#!/bin/sh\nexit 0\n");
write_executable(File::Spec->catfile($tool_bin, 'curl'), <<'SH');
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    printf 'vim-plug test fixture\n' > "$1"
  fi
  shift
done
SH

my $full_home = File::Spec->catdir($tool_home, 'home');
mkdir $full_home or die "Cannot create fake installer home: $!";
my $full_installer = Vim::Tools::Java::Installer->new(
    root => '.', home => $full_home,
    env => { PATH => $tool_bin, HOME => $full_home },
);
my $vim_test_log = File::Spec->catfile($tool_home, 'vim-commands.txt');
my ($dry_plan, $full_plan);
{
    local $ENV{VIM_TEST_LOG} = $vim_test_log;
    $dry_plan = $full_installer->run(dry_run => 1, show_config => 1);
    $full_plan = $full_installer->run;
}
is($dry_plan->{ai_provider}, 'copilot', 'installer dry-run selects the configured AI provider');
is($dry_plan->{ai_cli}, File::Spec->catfile($tool_bin, 'copilot'), 'installer locates the selected AI CLI');
is($dry_plan->{debugger}, 1, 'installer enables debugging when Python host support is available');
is_deeply($dry_plan->{missing}, [], 'installer reports no missing prerequisites for a complete toolchain');
like($dry_plan->{vimrc_block}, qr/vim_tools_ai_provider = 'copilot'/, 'dry-run can include the generated managed config');

is($full_plan->{ai_provider}, 'copilot', 'installer returns its selected provider after installation');
ok(-s File::Spec->catfile($full_home, '.vim', 'autoload', 'plug.vim'), 'installer downloads vim-plug when absent');
ok(-f File::Spec->catfile($full_home, '.vim', 'after', 'plugin', 'ai-tools.vim'), 'installer installs AI completion during a full setup');
open my $vim_log_fh, '<', $vim_test_log or die $!;
my $vim_commands = do { local $/; <$vim_log_fh> };
close $vim_log_fh;
like($vim_commands, qr/CocInstall -sync coc-java coc-java-debug/, 'installer requests Java debug Coc extension when Python support is available');

ok(!Vim::Tools::Java::Installer::_python3_10(File::Spec->catdir($tool_home, 'missing-bin')), 'Python host check returns false when Python is unavailable');
my $old_python_bin = File::Spec->catdir($tool_home, 'old-python');
make_path($old_python_bin);
write_executable(File::Spec->catfile($old_python_bin, 'python3'), "#!/bin/sh\nprintf 'Python 3.9.18\\n'\n");
ok(!Vim::Tools::Java::Installer::_python3_10($old_python_bin), 'Python host check rejects versions before 3.10');
is(Vim::Tools::Java::Installer::_version_ge('v22.15.0', 22, 15, 0), 1, 'version comparison accepts equal minimum versions');
is(Vim::Tools::Java::Installer::_version_ge('v23.0.0', 22, 15, 0), 1, 'version comparison accepts a higher major');
is(Vim::Tools::Java::Installer::_version_ge('v21.99.0', 22, 15, 0), 0, 'version comparison rejects a lower major');
is(Vim::Tools::Java::Installer::_version_ge('v22.16.0', 22, 15, 0), 1, 'version comparison accepts a higher minor');
is(Vim::Tools::Java::Installer::_version_ge('v22.14.9', 22, 15, 0), 0, 'version comparison rejects a lower minor');
is(Vim::Tools::Java::Installer::_version_ge('not-a-version', 22, 15, 0), 0, 'version comparison rejects unparseable values');
is(Vim::Tools::Java::Installer::_find_executable('absent-tool', $tool_bin), undef, 'executable lookup returns undef when no match exists');
is(Vim::Tools::Java::Installer::_capture(File::Spec->catfile($tool_bin, 'node'), '--version'), "v22.15.0\n", 'capture reads successful command output');
is(Vim::Tools::Java::Installer::_capture('/usr/bin/false'), undef, 'capture returns undef when a command fails');
is(Vim::Tools::Java::Installer::_run(File::Spec->catfile($tool_bin, 'git')), 0, 'run returns a successful command status');
my $checked_ok = eval { Vim::Tools::Java::Installer::_run_checked(File::Spec->catfile($tool_bin, 'git')); 1 };
ok($checked_ok, 'checked run accepts a successful command');
my $checked_fail = eval { Vim::Tools::Java::Installer::_run_checked('/usr/bin/false'); 1 };
ok(!$checked_fail && $@ =~ /Command failed/, 'checked run reports a failed command');

my $jdk_home = File::Spec->catdir($tool_home, 'jdk-17');
make_path(File::Spec->catdir($jdk_home, 'bin'));
write_executable(File::Spec->catfile($jdk_home, 'bin', 'java'), "#!/bin/sh\nexit 0\n");
my $jdk21_home = File::Spec->catdir($tool_home, 'jdk-21');
make_path(File::Spec->catdir($jdk21_home, 'bin'));
write_executable(File::Spec->catfile($jdk21_home, 'bin', 'java'), "#!/bin/sh\nexit 0\n");
my $jdk_plan = $full_installer->run(dry_run => 1, jdk => ["17=$jdk_home", "21=$jdk21_home"]);
is($jdk_plan->{jdks}[0]{major}, 17, 'installer accepts a valid explicit JDK');
is($jdk_plan->{jdks}[0]{home}, abs_path($jdk_home), 'explicit JDK replaces the detected path for that Java version');
is_deeply([map { $_->{major} } @{ $jdk_plan->{jdks} }], [17, 21], 'installer sorts multiple explicitly configured JDKs');
for my $case (
    [['invalid'], qr/Invalid --jdk/, 'rejects malformed explicit JDK specifications'],
    [['17=/missing'], qr/No executable Java found/, 'rejects explicit JDK paths without Java'],
) {
    my $accepted = eval { $full_installer->run(dry_run => 1, jdk => $case->[0]); 1 };
    ok(!$accepted && $@ =~ $case->[1], $case->[2]);
}

my $wget_bin = File::Spec->catdir($tool_home, 'wget-bin');
make_path($wget_bin);
write_executable(File::Spec->catfile($wget_bin, 'wget'), "#!/bin/sh\nwhile [ \"\$#\" -gt 0 ]; do if [ \"\$1\" = \"-O\" ]; then shift; printf 'vim-plug from wget\\n' > \"\$1\"; fi; shift; done\n");
my $wget_installer = Vim::Tools::Java::Installer->new(root => '.', home => $tool_home, env => { PATH => $wget_bin });
my $wget_plug = File::Spec->catfile($tool_home, 'wget-vim', 'plug.vim');
$wget_installer->_ensure_plug($wget_plug);
ok(-s $wget_plug, 'installer downloads vim-plug with wget when curl is unavailable');
$wget_installer->_ensure_plug($wget_plug);
ok(-s $wget_plug, 'installer reuses an existing vim-plug file');
my $empty_curl_bin = File::Spec->catdir($tool_home, 'empty-curl-bin');
make_path($empty_curl_bin);
write_executable(File::Spec->catfile($empty_curl_bin, 'curl'), "#!/bin/sh\nexit 0\n");
my $empty_installer = Vim::Tools::Java::Installer->new(root => '.', home => $tool_home, env => { PATH => $empty_curl_bin });
my $empty_download = eval { $empty_installer->_ensure_plug(File::Spec->catfile($tool_home, 'empty-vim', 'plug.vim')); 1 };
ok(!$empty_download && $@ =~ /download returned an empty file/, 'installer rejects an empty vim-plug download');
my $no_fetch_installer = Vim::Tools::Java::Installer->new(root => '.', home => $tool_home, env => { PATH => '' });
my $no_fetch = eval { $no_fetch_installer->_ensure_plug(File::Spec->catfile($tool_home, 'no-fetch', 'plug.vim')); 1 };
ok(!$no_fetch && $@ =~ /curl or wget is required/, 'installer reports when neither downloader is available');

done_testing;

sub write_executable {
    my ($path, $contents) = @_;
    open my $fh, '>', $path or die "Cannot create $path: $!";
    print {$fh} $contents;
    close $fh;
    chmod 0755, $path or die "Cannot mark $path executable: $!";
}

sub vim_string {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/''/g;
    return "'$value'";
}
