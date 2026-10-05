use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $vim = `command -v vim 2>/dev/null`;
chomp $vim;
if (!$vim || $^O eq 'MSWin32') {
    plan skip_all => 'this integration test requires classic Vim on a Unix-like system';
}

my $tmp = tempdir(CLEANUP => 1);
my $bin = File::Spec->catdir($tmp, 'bin');
my $workspace = File::Spec->catdir($tmp, 'workspace');
mkdir $bin or die "Cannot create fake CLI directory: $!";
mkdir $workspace or die "Cannot create fake workspace directory: $!";
$workspace = abs_path($workspace);
my $directory_file = File::Spec->catfile($workspace, 'directory-context.txt');
open my $directory_fh, '>', $directory_file or die "Cannot create workspace context file: $!";
print {$directory_fh} "DIRECTORY_CONTEXT_MARKER\n";
close $directory_fh;
my $external_file = File::Spec->catfile($tmp, 'external.pl');
open my $external_fh, '>', $external_file or die "Cannot create external buffer fixture: $!";
print {$external_fh} "EXTERNAL_BUFFER_MARKER\n";
close $external_fh;
my $plugin = abs_path(File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'ai-tools.vim'));
my %expected = (
    copilot => 'copilot generated text',
    codex => 'codex generated text',
    claude => 'claude generated text',
);

for my $provider (qw(copilot codex claude)) {
    my $cli = File::Spec->catfile($bin, $provider);
    open my $fake, '>', $cli or die "Cannot write fake CLI: $!";
    print {$fake} <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(getcwd);
my $provider = $ENV{VIM_AI_TEST_PROVIDER};
my ($prompt, $output_path);
if ($provider eq 'copilot') {
    for my $index (0 .. $#ARGV - 1) {
        if ($ARGV[$index] eq '-p') {
            $prompt = $ARGV[$index + 1];
            last;
        }
    }
} else {
    $prompt = $ARGV[-1];
}
for my $index (0 .. $#ARGV - 1) {
    if ($ARGV[$index] eq '--output-last-message') {
        $output_path = $ARGV[$index + 1];
    }
}
open my $capture, '>>', $ENV{VIM_AI_TEST_PROMPT} or die $!;
print {$capture} "\n<<<VIM_AI_TEST_REQUEST>>>\n", defined($prompt) ? $prompt : '';
close $capture;
select undef, undef, undef, 0.2;
open my $cwd_capture, '>', $ENV{VIM_AI_TEST_CWD} or die $!;
print {$cwd_capture} getcwd(), "\n";
if (open my $directory, '<', 'directory-context.txt') {
    print {$cwd_capture} <$directory>;
    close $directory;
}
close $cwd_capture;
open my $args_capture, '>', $ENV{VIM_AI_TEST_ARGS} or die $!;
print {$args_capture} join("\n", @ARGV);
close $args_capture;
if (defined $output_path) {
    open my $output, '>', $output_path or die $!;
    print {$output} $ENV{VIM_AI_TEST_REPLY};
    close $output;
} else {
    print $ENV{VIM_AI_TEST_REPLY}, "\n";
}
PERL
    close $fake;
    chmod 0755, $cli or die "Cannot make fake CLI executable: $!";

    my $result = File::Spec->catfile($tmp, "$provider-result.txt");
    my $generated = File::Spec->catfile($tmp, "$provider-generated.txt");
    my $prompt_capture = File::Spec->catfile($tmp, "$provider-prompt.txt");
    my $cwd_capture = File::Spec->catfile($tmp, "$provider-cwd.txt");
    my $args_capture = File::Spec->catfile($tmp, "$provider-args.txt");
    my $ghost = File::Spec->catfile($tmp, "$provider-ghost.txt");
    my $dismissed = File::Spec->catfile($tmp, "$provider-dismissed.txt");
    my $accepted = File::Spec->catfile($tmp, "$provider-accepted.txt");
    my $script = File::Spec->catfile($tmp, "$provider-test.vim");
    my $log = File::Spec->catfile($tmp, "$provider-vim.log");
    open my $vimscript, '>', $script or die "Cannot write Vim script: $!";
    print {$vimscript} "let g:vim_tools_ai_provider = '$provider'\n";
    print {$vimscript} "source $plugin\n";
    print {$vimscript} "function! VimToolsTestLateTab() abort\n  return 'LATE-TAB-FALLBACK'\nendfunction\n";
    print {$vimscript} "inoremap <silent><expr> <Tab> VimToolsTestLateTab()\ndoautocmd VimEnter\n";
    print {$vimscript} "call writefile([string(maparg('<Tab>', 'i', 0, 1)), VimToolsAIAcceptTab()], '$tmp/$provider-tab.txt')\n";
    print {$vimscript} "execute 'lcd ' . fnameescape(" . vim_quote($workspace) . ")\n";
    print {$vimscript} "execute 'edit ' . fnameescape(" . vim_quote(File::Spec->catfile($workspace, 'current.pl')) . ")\n";
    print {$vimscript} "call setline(1, ['old source', 'old extra'])\nsetfiletype perl\n";
    print {$vimscript} "call VimToolsAIGenerate(1, 2, 'replace this')\n";
    print {$vimscript} "sleep 1500m\n";
    print {$vimscript} "call writefile([getline(1)], '$generated')\n";
    print {$vimscript} "call setline(1, ['CURRENT_FILE_CONTEXT_MARKER'])\n";
    print {$vimscript} "call append(1, repeat(['sub support { return 42; }'], 100))\ncall append(101, '')\n";
    print {$vimscript} "call cursor(102, 1)\n";
    print {$vimscript} "let g:open_buffer = bufadd(" . vim_quote(File::Spec->catfile($workspace, 'opened.pl')) . ")\n";
    print {$vimscript} "call bufload(g:open_buffer)\ncall setbufline(g:open_buffer, 1, ['OPEN_BUFFER_CONTEXT_MARKER'])\n";
    print {$vimscript} "let g:external_buffer = bufadd(" . vim_quote($external_file) . ")\n";
    print {$vimscript} "call bufload(g:external_buffer)\ncall setbufline(g:external_buffer, 1, ['EXTERNAL_BUFFER_MARKER'])\n";
    print {$vimscript} "call VimToolsAIComplete()\nlet v:errmsg = ''\ncall VimToolsAIComplete()\n";
    print {$vimscript} "let g:auto_fn = matchstr(execute('function /AutoComplete'), '<SNR>\\d\\+_AutoComplete')\n";
    print {$vimscript} "let g:timers_before = len(timer_info())\n";
    print {$vimscript} "execute 'call ' . g:auto_fn . '(0)'\nlet g:timers_after = len(timer_info())\n";
    print {$vimscript} "sleep 1500m\nexecute 'buffer! ' . g:open_buffer\ncall VimToolsAIAccept()\n";
    print {$vimscript} "call writefile([expand('%:p'), getline(102)], '$result')\n";
    print {$vimscript} "call writefile([v:errmsg], '$tmp/$provider-errmsg.txt')\n";
    print {$vimscript} "call writefile([string(g:timers_before), string(g:timers_after)], '$tmp/$provider-timers.txt')\n";
    print {$vimscript} "if has('patch-9.0.0185')\n";
    print {$vimscript} "  let g:show_fn = matchstr(execute('function /ShowSuggestion'), '<SNR>\\d\\+_ShowSuggestion')\n";
    print {$vimscript} "  execute 'call ' . g:show_fn . '(' . string('inline suggestion') . ')'\n";
    print {$vimscript} "  call writefile([string(prop_list(102))], '$ghost')\n";
    print {$vimscript} "  let g:accept_keys = VimToolsAIAcceptTab()\n";
    print {$vimscript} "  call writefile([string(g:accept_keys), VimToolsAIQueuedSuggestion(), string(prop_list(102))], '$accepted')\nAIDismiss\n";
    print {$vimscript} "  call writefile([string(prop_list(102))], '$dismissed')\nendif\n";
    print {$vimscript} "qa!\n";
    close $vimscript;

    local $ENV{PATH} = "$bin:$ENV{PATH}";
    local $ENV{VIM_AI_TEST_PROVIDER} = $provider;
    local $ENV{VIM_AI_TEST_PROMPT} = $prompt_capture;
    local $ENV{VIM_AI_TEST_CWD} = $cwd_capture;
    local $ENV{VIM_AI_TEST_ARGS} = $args_capture;
    local $ENV{VIM_AI_TEST_REPLY} = $expected{$provider};
    my $status = system($vim, '-Nu', 'NONE', '-n', '-i', 'NONE', '-es', "-V1$log", '-S', $script);
    if ($status != 0 && -f $log) {
        open my $log_fh, '<', $log or die $!;
        my $details = do { local $/; <$log_fh> // '' };
        close $log_fh;
        diag($details);
    }
    is($status, 0, "$provider CLI request runs inside Vim");
    open my $tab_fh, '<', "$tmp/$provider-tab.txt" or die "No Tab mapping result for $provider: $!";
    my @tab_result = <$tab_fh>;
    close $tab_fh;
    like($tab_result[0], qr/VimToolsAIAcceptTab\(\)/, "$provider Tab mapping is restored after later plugin mappings");
    is($tab_result[1], "LATE-TAB-FALLBACK\n", "$provider Tab mapping preserves the later plugin fallback");
    for my $case ([generation => $generated], [completion => $result]) {
        open my $output, '<', $case->[1] or die "No Vim output for $provider: $!";
        my @lines = <$output>;
        close $output;
        chomp @lines;
        my $expected_lines = $case->[0] eq 'completion'
            ? [File::Spec->catfile($workspace, 'current.pl'), $expected{$provider}]
            : [$expected{$provider}];
        is_deeply(\@lines, $expected_lines, "$provider $case->[0] returns its response to the expected buffer");
    }
    open my $prompt_fh, '<', $prompt_capture or die "No completion prompt from $provider: $!";
    my $prompt = do { local $/; <$prompt_fh> // '' };
    close $prompt_fh;
    like($prompt, qr/CURRENT_FILE_CONTEXT_MARKER/, "$provider receives the full current file");
    like($prompt, qr/<<<CURSOR>>>/, "$provider receives the exact cursor position");
    like($prompt, qr/OPEN_BUFFER_CONTEXT_MARKER/, "$provider receives other open file buffers");
    unlike($prompt, qr/EXTERNAL_BUFFER_MARKER/, "$provider skips buffers outside the workspace");
    like($prompt, qr/Workspace directory: \Q$workspace\E/, "$provider is told the Vim working directory");
    like($prompt, qr/Do not call tools, run commands, or modify files/, "$provider receives a direct, context-only completion prompt");
    like($prompt, qr/CURRENT_FILE_CONTEXT_MARKER/, "$provider receives file context beyond the former context window");
    my $request_count = () = $prompt =~ /<<<VIM_AI_TEST_REQUEST>>>/g;
    is($request_count, 2, "$provider receives generation and completion requests");
    open my $errmsg_fh, '<', "$tmp/$provider-errmsg.txt" or die $!;
    my $vim_error = do { local $/; <$errmsg_fh> // '' };
    close $errmsg_fh;
    is($vim_error, "\n", "$provider timer handles a running Vim Job without errors");
    open my $timers_fh, '<', "$tmp/$provider-timers.txt" or die $!;
    my @timers = <$timers_fh>;
    close $timers_fh;
    chomp @timers;
    is_deeply(\@timers, [0, 0], "$provider auto-completion does not poll while an AI request is running");
    open my $cwd_fh, '<', $cwd_capture or die "No CLI working directory from $provider: $!";
    my $cwd_context = do { local $/; <$cwd_fh> // '' };
    close $cwd_fh;
    like($cwd_context, qr/^\Q$workspace\E\nDIRECTORY_CONTEXT_MARKER/m, "$provider runs in and can read Vim's working directory");
    open my $args_fh, '<', $args_capture or die "No CLI arguments from $provider: $!";
    my $args = do { local $/; <$args_fh> // '' };
    close $args_fh;
    if ($provider eq 'copilot') {
        unlike($args, qr/--deny-tool=(?:read|grep|glob)(?:\n|$)/, 'Copilot retains read/search tools for workspace context');
        like($args, qr/--deny-tool=write/, 'Copilot write access remains disabled');
        like($args, qr/--deny-tool=shell/, 'Copilot shell access remains disabled');
    } elsif ($provider eq 'codex') {
        like($args, qr/--sandbox\nread-only/, 'Codex workspace access remains read-only');
    } else {
        like($args, qr/--permission-mode\nplan/, 'Claude workspace access remains in plan mode');
    }
    if (-f $ghost && -f $dismissed && -f $accepted) {
        open my $ghost_fh, '<', $ghost or die $!;
        my $ghost_props = do { local $/; <$ghost_fh> // '' };
        close $ghost_fh;
        like($ghost_props, qr/inline suggestion/, "$provider suggestion is rendered as Vim virtual text");
        open my $accepted_fh, '<', $accepted or die $!;
        my @accepted_result = <$accepted_fh>;
        close $accepted_fh;
        like($accepted_result[0], qr/VimToolsAIQueuedSuggestion\(\)/, "$provider Tab acceptance queues the ghost text for insertion");
        is($accepted_result[1], "inline suggestion\n", "$provider Tab acceptance retains the exact suggestion");
        is($accepted_result[2], "[]\n", "$provider Tab acceptance clears the ghost property");
        open my $dismissed_fh, '<', $dismissed or die $!;
        my $dismissed_props = do { local $/; <$dismissed_fh> // '' };
        close $dismissed_fh;
        is($dismissed_props, "[]\n", "$provider virtual suggestion clears cleanly");
    }

    test_automatic_completion(
        vim => $vim,
        provider => $provider,
        expected => $expected{$provider},
        plugin => $plugin,
        tmp => $tmp,
        bin => $bin,
    );
}

done_testing;

sub vim_quote {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/''/g;
    return "'$value'";
}

sub test_automatic_completion {
    my (%args) = @_;
    my $tmux = `command -v tmux 2>/dev/null`;
    chomp $tmux;
    if (!$tmux) {
        skip 'automatic insert-mode integration requires tmux', 5;
        return;
    }

    my $provider = $args{provider};
    my $name = "vim-ai-auto-$$-$provider";
    my $file = File::Spec->catfile($args{tmp}, "$provider-auto.pl");
    my $prompt_file = File::Spec->catfile($args{tmp}, "$provider-auto-prompt.txt");
    my $cwd_file = File::Spec->catfile($args{tmp}, "$provider-auto-cwd.txt");
    my $args_file = File::Spec->catfile($args{tmp}, "$provider-auto-args.txt");
    open my $source, '>', $file or die "Cannot create auto-completion fixture: $!";
    print {$source} "sub automatic {\n\n}\n";
    close $source;

    my @command = (
        '/usr/bin/env',
        "PATH=$args{bin}:$ENV{PATH}",
        "VIM_AI_TEST_PROVIDER=$provider",
        "VIM_AI_TEST_PROMPT=$prompt_file",
        "VIM_AI_TEST_CWD=$cwd_file",
        "VIM_AI_TEST_ARGS=$args_file",
        "VIM_AI_TEST_REPLY=$args{expected}",
        $args{vim}, '-Nu', 'NONE', '-n', '-i', 'NONE', $file,
        '-c', "let g:vim_tools_ai_provider='$provider'",
        '-c', "source $args{plugin}",
        '-c', 'setfiletype perl',
        '-c', 'normal! 2G$',
        '-c', 'startinsert',
    );
    my $start_status = system($tmux, 'new-session', '-d', '-s', $name, '-x', '100', '-y', '30', @command);
    is($start_status, 0, "$provider insert-mode Vim session starts in tmux");
    if ($start_status != 0) {
        skip "$provider tmux session could not start", 4;
        return;
    }

    select undef, undef, undef, 1.5;
    ok(!-e $prompt_file, "$provider does not request completion just on InsertEnter");
    my $target = "$name:0.0";
    system($tmux, 'send-keys', '-t', $target, '-l', 'return ');

    my $pane = '';
    for (1 .. 50) {
        select undef, undef, undef, 0.1;
        $pane = capture_tmux_pane($tmux, $target);
        last if $pane =~ /\Q$args{expected}\E/;
    }
    like($pane, qr/\Q$args{expected}\E/, "$provider displays an automatic suggestion after typing");

    system($tmux, 'send-keys', '-t', $target, 'Tab');
    select undef, undef, undef, 0.2;
    system($tmux, 'send-keys', '-t', $target, 'Escape', ':wq', 'Enter');
    for (1 .. 30) {
        last unless tmux_session_exists($tmux, $name);
        select undef, undef, undef, 0.1;
    }
    my @contents = -f $file ? do {
        open my $result, '<', $file or die "Cannot read auto-completion fixture: $!";
        my @lines = <$result>;
        close $result;
        chomp @lines;
        @lines;
    } : ();
    is($contents[1], "return $args{expected}", "$provider Tab accepts the automatic suggestion");

    if (-f $prompt_file) {
        open my $prompt, '<', $prompt_file or die "Cannot read auto-completion prompt: $!";
        my $text = do { local $/; <$prompt> // '' };
        close $prompt;
        like($text, qr/return\s+<<<CURSOR>>>/, "$provider autocomplete prompt includes text typed in Insert mode");
    } else {
        fail "$provider autocomplete prompt includes text typed in Insert mode";
    }
    system($tmux, 'kill-session', '-t', $name) if tmux_session_exists($tmux, $name);
}

sub capture_tmux_pane {
    my ($tmux, $target) = @_;
    open my $capture, '-|', $tmux, 'capture-pane', '-p', '-t', $target or die "Cannot capture tmux pane: $!";
    my $text = do { local $/; <$capture> // '' };
    close $capture;
    return $text;
}

sub tmux_session_exists {
    my ($tmux, $name) = @_;
    return system("$tmux has-session -t $name >/dev/null 2>&1") == 0;
}
