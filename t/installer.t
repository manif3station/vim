use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
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
like($vimrc, qr/clipboard=unnamedplus,autoselect/, 'mouse and Visual selections use the host clipboard');
open my $navigation_asset, '<', File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'java-tools.vim') or die $!;
my $navigation = do { local $/; <$navigation_asset> };
close $navigation_asset;
unlike($navigation, qr/nnoremap <silent> g[tT] /, 'gt and gT keep Vim default tab navigation');
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
like($ai_plugin, qr/prop_add\(line\('\.'\), col\('\.'\), \{'type': 'VimToolsAICompletion', 'text': a:text\}\)/, 'AI suggestions render as virtual text when Vim supports it');
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

done_testing;
