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
    my $script = File::Spec->catfile($tmp, "$provider-test.vim");
    my $log = File::Spec->catfile($tmp, "$provider-vim.log");
    open my $vimscript, '>', $script or die "Cannot write Vim script: $!";
    print {$vimscript} "let g:vim_tools_ai_provider = '$provider'\n";
    print {$vimscript} "source $plugin\n";
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
    print {$vimscript} "call VimToolsAIComplete()\nlet v:errmsg = ''\ncall VimToolsAIComplete()\n";
    print {$vimscript} "let g:auto_fn = matchstr(execute('function /AutoComplete'), '<SNR>\\d\\+_AutoComplete')\n";
    print {$vimscript} "let g:timers_before = len(timer_info())\n";
    print {$vimscript} "execute 'call ' . g:auto_fn . '(0)'\nlet g:timers_after = len(timer_info())\n";
    print {$vimscript} "sleep 1500m\nexecute 'buffer! ' . g:open_buffer\ncall VimToolsAIAccept()\n";
    print {$vimscript} "call writefile([expand('%:p'), getline(102)], '$result')\n";
    print {$vimscript} "call writefile([v:errmsg], '$tmp/$provider-errmsg.txt')\n";
    print {$vimscript} "call writefile([string(g:timers_before), string(g:timers_after)], '$tmp/$provider-timers.txt')\n";
    print {$vimscript} "if has('patch-9.2.0000')\n";
    print {$vimscript} "  let g:show_fn = matchstr(execute('function /ShowSuggestion'), '<SNR>\\d\\+_ShowSuggestion')\n";
    print {$vimscript} "  execute 'call ' . g:show_fn . '(' . string('inline suggestion') . ')'\n";
    print {$vimscript} "  call writefile([string(prop_list(102))], '$ghost')\nAIDismiss\n";
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
    like($prompt, qr/Workspace directory: \Q$workspace\E/, "$provider is told the Vim working directory");
    like($prompt, qr/Inspect relevant files and project instructions in the workspace using read-only file tools/, "$provider is instructed to inspect workspace context read-only");
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
    if (-f $ghost && -f $dismissed) {
        open my $ghost_fh, '<', $ghost or die $!;
        my $ghost_props = do { local $/; <$ghost_fh> // '' };
        close $ghost_fh;
        like($ghost_props, qr/inline suggestion/, "$provider suggestion is rendered as Vim virtual text");
        open my $dismissed_fh, '<', $dismissed or die $!;
        my $dismissed_props = do { local $/; <$dismissed_fh> // '' };
        close $dismissed_fh;
        is($dismissed_props, "[]\n", "$provider virtual suggestion clears cleanly");
    }
}

done_testing;

sub vim_quote {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/''/g;
    return "'$value'";
}
