package Vim::Tools::Java::Installer;

use strict;
use warnings;
use Exporter qw(import);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use Vim::Tools::Java::Jdk qw(discover_jdks major_version runtime_name runtime_settings);
use Vim::Tools::AI::Config qw(ai_provider);

our @EXPORT_OK = qw(new run render_vimrc);

sub new {
    my ($class, %args) = @_;
    my $root = abs_path($args{root} // '.') || $args{root} // '.';
    my $home = $args{home} // $ENV{HOME} // $ENV{USERPROFILE};
    die "Cannot determine home directory.\n" unless defined $home && length $home;
    my $windows = exists $args{windows} ? $args{windows} : ($^O eq 'MSWin32');
    my $vim_home = File::Spec->catdir($home, $windows ? 'vimfiles' : '.vim');
    return bless {
        root => $root, home => $home, windows => $windows,
        vim_home => $args{vim_home} // $vim_home,
        vimrc => $args{vimrc} // File::Spec->catfile($home, $windows ? '_vimrc' : '.vimrc'),
        env => $args{env} || \%ENV,
    }, $class;
}

sub run {
    my ($self, %opts) = @_;
    my $vim = $opts{vim} || _find_executable($self->{windows} ? 'vim.exe' : 'vim', $self->{env}{PATH});
    die "Classic Vim was not found. Install Vim 9.0.0438+ or pass --vim PATH.\n" unless $vim;
    my $version = _capture($vim, '--version');
    die "Could not execute Vim at '$vim'.\n" unless defined $version;
    die "'$vim' is Neovim. This installer configures classic Vim only.\n" if $version =~ /NVIM/i;
    my $check = q{if v:version < 900 || !has('patch-9.0.0438') || !has('job') || !has('channel') || !has('terminal') || !has('timers') | cquit | endif | qa!};
    _run($vim, '-Nu', 'NONE', '-n', '-es', '-c', $check) == 0
      or die "Vim must be version 9.0.0438+ with +job, +channel, +terminal, and +timers.\n";

    my $jdks = discover_jdks(
        home => $self->{home}, java_home => $self->{env}{JAVA_HOME}, path => $self->{env}{PATH}, windows => $self->{windows},
    );
    my $ai_provider = ai_provider(root => $self->{root}, env => $self->{env});
    my $ai_cli = _find_executable($self->{windows} ? "$ai_provider.exe" : $ai_provider, $self->{env}{PATH});
    for my $spec (@{ $opts{jdk} || [] }) {
        $spec =~ /^([0-9]+(?:\.[0-9]+)*)(?:=|:)(.+)$/ or die "Invalid --jdk '$spec'; use --jdk VERSION=PATH.\n";
        my ($major, $path) = (major_version($1), $2);
        defined $major or die "Cannot interpret Java version in '$spec'.\n";
        my $java = File::Spec->catfile($path, 'bin', $self->{windows} ? 'java.exe' : 'java');
        -x $java or die "No executable Java found at '$java'.\n";
        _replace_jdk($jdks, $major, $path);
    }
    @$jdks = sort { $a->{major} <=> $b->{major} } @$jdks;

    my $python_debugger = !$self->{windows} && !$opts{no_debugger} && $version =~ /\+python3/
        && _python3_10($self->{env}{PATH});
    my $node = _find_executable($self->{windows} ? 'node.exe' : 'node', $self->{env}{PATH});
    my $node_version = $node ? _capture($node, '--version') : undef;
    my @missing;
    push @missing, 'Node.js 22.15.0+' unless $node_version && _version_ge($node_version, 22, 15, 0);
    push @missing, 'git' unless _find_executable($self->{windows} ? 'git.exe' : 'git', $self->{env}{PATH});
    push @missing, 'curl or wget' unless _find_executable($self->{windows} ? 'curl.exe' : 'curl', $self->{env}{PATH}) || _find_executable($self->{windows} ? 'wget.exe' : 'wget', $self->{env}{PATH});
    push @missing, "$ai_provider CLI" unless $ai_cli;
    die "Missing prerequisites: " . join(', ', @missing) . ".\n" if @missing && !$opts{dry_run};

    my $vimrc_block = render_vimrc(
        vim_home => $self->{vim_home}, jdks => $jdks, debugger => $python_debugger,
        ai_provider => $ai_provider,
    );
    my $plan = {
        vim => $vim, vim_version => $version,
        vimrc => $self->{vimrc}, vim_home => $self->{vim_home}, jdks => $jdks,
        debugger => $python_debugger ? 1 : 0, node_version => $node_version,
        ai_provider => $ai_provider, ai_cli => $ai_cli, missing => \@missing,
    };
    if ($opts{dry_run}) {
        $plan->{vimrc_block} = $vimrc_block if $opts{show_config};
        return $plan;
    }

    my $plug = File::Spec->catfile($self->{vim_home}, 'autoload', 'plug.vim');
    $self->_ensure_plug($plug);
    $self->_write_vimrc($vimrc_block);
    $self->_install_assets;
    my @base = ($vim, '-Nu', $self->{vimrc}, '-n', '-i', 'NONE', '-es', '--cmd', 'let g:vim_tools_java_installer_noninteractive=1');
    _run_checked(@base, '-c', 'PlugInstall --sync', '-c', 'qa!');
    my @extensions = qw(coc-java);
    push @extensions, 'coc-java-debug' if $python_debugger;
    _run_checked(@base, '-c', 'CocInstall -sync ' . join(' ', @extensions), '-c', 'qa!');
    return $plan;
}

sub render_vimrc {
    my (%args) = @_;
    my $home = $args{vim_home} // '~/.vim';
    $home =~ s!\\!/!g;
    $home =~ s!'!''!g;
    my $settings = {
        'java.signatureHelp.enabled' => JSON::PP::true,
        'java.contentProvider.preferred' => 'fernflower',
        'java.eclipse.downloadSources' => JSON::PP::true,
        'java.maven.downloadSources' => JSON::PP::true,
        'java.references.includeDecompiledSources' => JSON::PP::true,
        'java.referencesCodeLens.enabled' => JSON::PP::true,
        'java.implementationsCodeLens.enabled' => JSON::PP::true,
        'java.configuration.updateBuildConfiguration' => 'interactive',
        'diagnostic.virtualText' => JSON::PP::false,
        'java.sources.organizeImports.starThreshold' => 9999,
        'java.sources.organizeImports.staticStarThreshold' => 9999,
        'java.completion.favoriteStaticMembers' => [
            'org.junit.Assert.*', 'org.junit.Assume.*', 'org.junit.jupiter.api.Assertions.*',
            'org.junit.jupiter.api.Assumptions.*', 'org.mockito.Mockito.*',
            'org.mockito.ArgumentMatchers.*', 'org.mockito.Answers.*', 'java.util.Objects.*',
        ],
        'java.configuration.runtimes' => runtime_settings($args{jdks} || []),
    };
    my $json = encode_json($settings);
    $json =~ s/'/''/g;
    my $conf = <<'VIM';
" >>> vim-tools-java BEGIN
set nocompatible hidden number signcolumn=yes cursorline colorcolumn=80
set splitright splitbelow scrolloff=4 sidescrolloff=8 updatetime=250 timeoutlen=400
set showmode showtabline=2 mouse=a laststatus=2
if has('termguicolors') | set termguicolors | endif
if has('clipboard') | set clipboard=unnamedplus,autoselect | endif
let mapleader = ' '
syntax on
filetype plugin indent on
VIM
    $conf .= "let g:coc_config_home = expand('$home/coc')\n";
    $conf .= "let g:coc_data_home = expand('$home/coc-data')\n";
    $conf .= "let g:coc_user_config = extend(get(g:, 'coc_user_config', {}), json_decode('$json'))\n";
    my $perlnavigator_path = File::Spec->catfile($home, 'tools', 'perlnavigator', 'node_modules', '.bin', 'perlnavigator');
    $perlnavigator_path =~ s/'/''/g;
    $conf .= "let g:vim_tools_perlnavigator_local = '$perlnavigator_path'\n";
    $conf .= <<'VIM';
let g:vim_tools_perlnavigator_executable = get(g:, 'vim_tools_perlnavigator_executable', 'perlnavigator')
if g:vim_tools_perlnavigator_executable ==# 'perlnavigator' && executable(g:vim_tools_perlnavigator_local)
  let g:vim_tools_perlnavigator_executable = g:vim_tools_perlnavigator_local
endif
let g:vim_tools_perl_completion = executable(g:vim_tools_perlnavigator_executable)
let g:coc_user_config = extend(get(g:, 'coc_user_config', {}), {'languageserver': {}}, 'keep')
if type(get(g:coc_user_config, 'languageserver', {})) isnot v:t_dict
  let g:coc_user_config.languageserver = {}
endif
if has_key(g:coc_user_config.languageserver, 'perlnavigator')
  call remove(g:coc_user_config.languageserver, 'perlnavigator')
endif
if has_key(g:coc_user_config.languageserver, 'perllanguageserver')
  call remove(g:coc_user_config.languageserver, 'perllanguageserver')
endif
let g:vim_tools_perllanguageserver_available = 0
if executable('perl')
  call system('perl -MPerl::LanguageServer -e 1 2>/dev/null')
  let g:vim_tools_perllanguageserver_available = v:shell_error == 0
endif
if g:vim_tools_perl_completion
  let g:coc_user_config.languageserver['perlnavigator'] = {
        \ 'command': g:vim_tools_perlnavigator_executable,
        \ 'args': ['--stdio'],
        \ 'filetypes': ['perl'],
        \ 'rootPatterns': ['cpanfile', 'Makefile.PL', 'Build.PL', 'dist.ini', '.git'],
        \ 'settings': {'perlnavigator': {'perlPath': 'perl', 'enableWarnings': v:true}}
        \ }
elseif g:vim_tools_perllanguageserver_available
  let g:coc_user_config.languageserver['perllanguageserver'] = {
        \ 'command': 'perl',
        \ 'args': ['-MPerl::LanguageServer', '-ePerl::LanguageServer::run'],
        \ 'filetypes': ['perl'],
        \ 'rootPatterns': ['Makefile.PL', 'Build.PL', 'dist.ini', '.git']
        \ }
endif
unlet g:vim_tools_perllanguageserver_available
unlet g:vim_tools_perlnavigator_local
VIM
    $conf .= "let g:ale_completion_enabled = 1\nlet g:ale_completion_autoimport = 1\n";
    $conf .= "if !exists('g:plugs')\n  call plug#begin(expand('$home/plugged'))\nendif\n";
    $conf .= <<'VIM';
Plug 'dense-analysis/ale'
Plug 'doums/darcula'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'preservim/nerdtree'
Plug 'Xuyuanp/nerdtree-git-plugin'
Plug 'vim-perl/vim-perl'
Plug 'vim-airline/vim-airline'
Plug 'tpope/vim-fugitive'
VIM
    $conf .= "Plug 'puremourning/vimspector'\n" if $args{debugger};
    $conf .= "let g:vim_tools_ai_provider = '" . ($args{ai_provider} // 'copilot') . "'\n";
    $conf .= 'let g:vim_tools_java_debugger_enabled = ' . ($args{debugger} ? "1\n" : "0\n");
    $conf .= <<'VIM';
call plug#end()
let g:ale_linters_explicit = 1
let g:ale_linters = {'perl': ['perl']}
function! s:PerlProjectRoot(path) abort
  let l:origin = a:path
  let l:directory = a:path
  while !empty(l:directory)
    if filereadable(l:directory . '/cpanfile')
          \ || filereadable(l:directory . '/Makefile.PL')
          \ || filereadable(l:directory . '/Build.PL')
          \ || filereadable(l:directory . '/dist.ini')
          \ || filereadable(l:directory . '/.git')
          \ || isdirectory(l:directory . '/.git')
      return l:directory
    endif
    let l:parent = fnamemodify(l:directory, ':h')
    if l:parent ==# l:directory
      break
    endif
    let l:directory = l:parent
  endwhile

  return l:origin
endfunction

function! s:ConfigurePerlLintOptions() abort
  let l:root = s:PerlProjectRoot(expand('%:p:h'))
  let l:lib = l:root . '/lib'
  let b:ale_perl_perl_options = '-c -Mwarnings'

  if isdirectory(l:lib)
    let b:ale_perl_perl_options .= ' -I' . shellescape(l:lib)
  endif
endfunction

augroup vim_tools_perl_lint
  autocmd!
  autocmd FileType perl call s:ConfigurePerlLintOptions()
augroup END
silent! colorscheme darcula
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#show_buffers = 1
let g:airline#extensions#coc#enabled = 1
let g:airline#extensions#coc#show_coc_status = 1
let g:airline#extensions#branch#enabled = 1
let g:airline_powerline_fonts = 0
let g:airline_symbols_ascii = 1
let g:NERDTreeShowHidden = 1
let g:NERDTreeWinSize = 28
nnoremap <silent> gd <Plug>(coc-definition)
nnoremap <silent> gr <Plug>(coc-references)
nnoremap <silent> K :call CocActionAsync('doHover')<CR>
nnoremap <silent> <leader>rn <Plug>(coc-rename)
nnoremap <silent> <leader>ca <Plug>(coc-codeaction)
nnoremap <silent> <leader>oi :call CocActionAsync('organizeImport')<CR>
nnoremap <silent> <leader>e :NERDTreeToggle<CR>
nnoremap <silent> <leader>tt :JavaTestNearest<CR>
nnoremap <silent> <leader>tf :JavaTestFile<CR>
nnoremap <silent> <leader>td :JavaDebugTestNearest<CR>
nnoremap <silent> <leader>tc :JavaFindTest<CR>
nnoremap <silent> <leader>cv :JavaCoverage<CR>
nnoremap <silent> gF <C-o>
inoremap <silent><expr> <C-Space> &filetype ==# 'java' ? coc#refresh() : "\<C-n>"
inoremap <silent><expr> <C-@> &filetype ==# 'java' ? coc#refresh() : "\<C-n>"
augroup vim_tools_perl_completion
  autocmd!
  if g:vim_tools_perl_completion
    autocmd FileType perl inoremap <buffer><silent><expr> <C-Space> coc#refresh()
    autocmd FileType perl inoremap <buffer><silent><expr> <C-@> coc#refresh()
  endif
augroup END
inoremap <silent><expr> <CR> coc#pum#visible() ? coc#pum#confirm() : "\<CR>"
inoremap <silent><expr> <Tab> coc#pum#visible() ? coc#pum#next(1) : "\<Tab>"
inoremap <silent><expr> <S-Tab> coc#pum#visible() ? coc#pum#prev(1) : "\<C-h>"
autocmd FileType java setlocal shiftwidth=4 softtabstop=4 expandtab
autocmd BufWritePre * if &modifiable | %s/\s\+$//e | endif
command! -bar JavaWrite call JavaWriteAndTest()
command! -bar JavaWriteExit call JavaWriteAndQuit()
cnoreabbrev <expr> W (getcmdtype() ==# ':' && getcmdline() ==# 'W') ? 'JavaWrite' : 'W'
cnoreabbrev <expr> X (getcmdtype() ==# ':' && getcmdline() ==# 'X') ? 'JavaWriteExit' : 'X'
if !exists('g:vim_tools_java_installer_noninteractive')
  autocmd VimEnter * if argc() == 0 | execute 'NERDTree' | wincmd p | endif
endif
VIM
    $conf .= "let g:vimspector_enable_mappings = 'HUMAN'\nnnoremap <F5> :CocCommand java.debug.vimspector.start<CR>\n" if $args{debugger};
    $conf .= "\" <<< vim-tools-java END\n";
    return $conf;
}

sub _install_assets {
    my ($self) = @_;
    my $assets = File::Spec->catdir($self->{root}, 'assets', 'vim');
    my $plugin_dir = File::Spec->catdir($self->{vim_home}, 'after', 'plugin');
    my $bin_dir = File::Spec->catdir($self->{vim_home}, 'bin');
    my $perl_root = File::Spec->catdir($self->{vim_home}, 'perl5', 'Vim', 'Tools', 'Java');
    my $perl_lookup_root = File::Spec->catdir($self->{vim_home}, 'perl5', 'Vim', 'Tools', 'Perl');
    make_path($plugin_dir, $bin_dir, $perl_root, $perl_lookup_root);
    copy(File::Spec->catfile($assets, 'after', 'plugin', 'java-tools.vim'), File::Spec->catfile($plugin_dir, 'java-tools.vim'))
      or die "Cannot install Vim Java plugin asset: $!\n";
    copy(File::Spec->catfile($assets, 'after', 'plugin', 'ai-tools.vim'), File::Spec->catfile($plugin_dir, 'ai-tools.vim'))
      or die "Cannot install Vim AI plugin asset: $!\n";
    copy(File::Spec->catfile($assets, 'bin', 'java-project.pl'), File::Spec->catfile($bin_dir, 'java-project.pl'))
      or die "Cannot install Java project helper: $!\n";
    chmod 0755, File::Spec->catfile($bin_dir, 'java-project.pl');
    for my $module (qw(Jdk.pm Project.pm Coverage.pm)) {
        copy(File::Spec->catfile($self->{root}, 'lib', 'Vim', 'Tools', 'Java', $module), File::Spec->catfile($perl_root, $module))
          or die "Cannot install Perl module $module: $!\n";
    }
    copy(File::Spec->catfile($self->{root}, 'lib', 'Vim', 'Tools', 'Perl', 'ModuleLookup.pm'), File::Spec->catfile($perl_lookup_root, 'ModuleLookup.pm'))
      or die "Cannot install Perl module lookup helper: $!\n";
}

sub _ensure_plug {
    my ($self, $path) = @_;
    return if -s $path;
    my $dir = dirname($path);
    make_path($dir);
    my $curl = _find_executable($self->{windows} ? 'curl.exe' : 'curl', $self->{env}{PATH});
    my $wget = _find_executable($self->{windows} ? 'wget.exe' : 'wget', $self->{env}{PATH});
    my $tmp = "$path.tmp.$$";
    if ($curl) {
        _run_checked($curl, '-fsSL', 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim', '-o', $tmp);
    } elsif ($wget) {
        _run_checked($wget, '-q', '-O', $tmp, 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim');
    } else { die "curl or wget is required to download vim-plug.\n" }
    -s $tmp or die "vim-plug download returned an empty file.\n";
    rename($tmp, $path) or die "Cannot move vim-plug into place: $!\n";
}

sub _replace_jdk {
    my ($jdks, $major, $path) = @_;
    @$jdks = grep { $_->{major} != $major } @$jdks;
    my $home = abs_path($path) || $path;
    push @$jdks, { major => $major, home => $home };
}

sub _write_vimrc {
    my ($self, $block) = @_;
    my $path = $self->{vimrc};
    my $begin = '" >>> vim-tools-java BEGIN';
    my $end = '" <<< vim-tools-java END';
    my $text = '';
    if (-e $path) {
        open my $fh, '<', $path or die "Cannot read '$path': $!\n";
        local $/;
        $text = <$fh> // '';
        close $fh;
    }
    my $has_begin = index($text, $begin) >= 0;
    my $has_end = index($text, $end) >= 0;
    die "Incomplete vim-tools-java markers in '$path'; repair them before reinstalling.\n" if $has_begin != $has_end;
    if ($has_begin) {
        $text =~ s/\Q$begin\E.*?\Q$end\E/$block/s or die "Could not replace managed Vim config block.\n";
    } else {
        $text .= "\n" if length($text) && $text !~ /\n\z/;
        $text .= "\n$block";
    }
    if (-e $path) {
        my $backup = $path . '.bak.' . strftime('%Y%m%d-%H%M%S', localtime);
        copy($path, $backup) or die "Cannot back up '$path' to '$backup': $!\n";
    }
    my $tmp = "$path.tmp.$$";
    open my $out, '>', $tmp or die "Cannot write '$tmp': $!\n";
    print {$out} $text or die "Cannot write '$tmp': $!\n";
    close $out or die "Cannot close '$tmp': $!\n";
    rename($tmp, $path) or die "Cannot install '$path': $!\n";
}

sub _python3_10 {
    my ($path) = @_;
    my $python = _find_executable('python3', $path);
    return 0 unless $python;
    my $version = _capture($python, '--version') // '';
    return $version =~ /Python\s+(\d+)\.(\d+)/ && ($1 > 3 || ($1 == 3 && $2 >= 10));
}

sub _version_ge {
    my ($text, $a, $b, $c) = @_;
    return 0 unless $text =~ /v?(\d+)\.(\d+)\.(\d+)/;
    return 1 if $1 > $a;
    return 0 if $1 < $a;
    return 1 if $2 > $b;
    return 0 if $2 < $b;
    return $3 >= $c;
}

sub _find_executable {
    my ($name, $path) = @_;
    $path //= $ENV{PATH} // '';
    my $separator = $^O eq 'MSWin32' ? ';' : ':';
    for my $dir (split(/\Q$separator\E/, $path)) {
        my $candidate = File::Spec->catfile(length($dir) ? $dir : '.', $name);
        return $candidate if -f $candidate && ($^O eq 'MSWin32' || -x $candidate);
    }
    return;
}

sub _capture {
    my (@cmd) = @_;
    open my $fh, '-|', @cmd or return;
    local $/;
    my $result = <$fh> // '';
    close $fh;
    return $? == 0 ? $result : undef;
}

sub _run {
    my (@cmd) = @_;
    system { $cmd[0] } @cmd;
    return $? == -1 ? 255 : $? >> 8;
}

sub _run_checked {
    my (@cmd) = @_;
    my $status = _run(@cmd);
    $status == 0 or die "Command failed ($status): @cmd\n";
}

1;
