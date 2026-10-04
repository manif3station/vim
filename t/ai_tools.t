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
mkdir $bin or die "Cannot create fake CLI directory: $!";
my $plugin = abs_path(File::Spec->catfile('assets', 'vim', 'after', 'plugin', 'ai-tools.vim'));
my %expected = (
    copilot => 'copilot generated text',
    codex => 'codex generated text',
    claude => 'claude generated text',
);

for my $provider (qw(copilot codex claude)) {
    my $cli = File::Spec->catfile($bin, $provider);
    open my $fake, '>', $cli or die "Cannot write fake CLI: $!";
    if ($provider eq 'codex') {
        print {$fake} <<'SH';
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out=$1
  fi
  shift
done
printf '%s' 'codex generated text' > "$out"
SH
    } else {
        print {$fake} "#!/bin/sh\nprintf '%s\\n' '$expected{$provider}'\n";
    }
    close $fake;
    chmod 0755, $cli or die "Cannot make fake CLI executable: $!";

    my $result = File::Spec->catfile($tmp, "$provider-result.txt");
    my $generated = File::Spec->catfile($tmp, "$provider-generated.txt");
    my $ghost = File::Spec->catfile($tmp, "$provider-ghost.txt");
    my $dismissed = File::Spec->catfile($tmp, "$provider-dismissed.txt");
    my $script = File::Spec->catfile($tmp, "$provider-test.vim");
    my $log = File::Spec->catfile($tmp, "$provider-vim.log");
    open my $vimscript, '>', $script or die "Cannot write Vim script: $!";
    print {$vimscript} "let g:vim_tools_ai_provider = '$provider'\n";
    print {$vimscript} "source $plugin\n";
    print {$vimscript} "call setline(1, ['old source', 'old extra'])\n";
    print {$vimscript} "call VimToolsAIGenerate(1, 2, 'replace this')\n";
    print {$vimscript} "sleep 1500m\n";
    print {$vimscript} "call writefile([getline(1)], '$generated')\n";
    print {$vimscript} "call setline(1, [''])\ncall cursor(1, 1)\n";
    print {$vimscript} "call VimToolsAIComplete()\nsleep 1500m\ncall VimToolsAIAccept()\n";
    print {$vimscript} "call writefile([getline(1)], '$result')\n";
    print {$vimscript} "if has('patch-9.2.0000')\n";
    print {$vimscript} "  let g:show_fn = matchstr(execute('function /ShowSuggestion'), '<SNR>\\d\\+_ShowSuggestion')\n";
    print {$vimscript} "  execute 'call ' . g:show_fn . '(' . string('inline suggestion') . ')'\n";
    print {$vimscript} "  call writefile([string(prop_list(1))], '$ghost')\nAIDismiss\n";
    print {$vimscript} "  call writefile([string(prop_list(1))], '$dismissed')\nendif\n";
    print {$vimscript} "qa!\n";
    close $vimscript;

    local $ENV{PATH} = "$bin:$ENV{PATH}";
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
        is_deeply(\@lines, [$expected{$provider}], "$provider $case->[0] returns its response into the buffer");
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
