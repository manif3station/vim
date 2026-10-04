#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use Getopt::Long qw(GetOptions);
use JSON::PP qw(encode_json);
use Vim::Tools::Java::Installer qw(new);

my ($help, $dry_run, $show_config, $no_debugger, $vim, $home);
my @jdk;
GetOptions(
    'help|h'       => \$help,
    'dry-run'      => \$dry_run,
    'show-config'  => \$show_config,
    'no-debugger'  => \$no_debugger,
    'vim=s'        => \$vim,
    'home=s'       => \$home,
    'jdk=s@'       => \@jdk,
) or usage(2);
usage(0) if $help;
@ARGV and die "Unexpected arguments: @ARGV\n";

my $root = abs_path("$FindBin::Bin/..") or die "Cannot locate project root from $FindBin::Bin\n";
my $installer = Vim::Tools::Java::Installer->new(root => $root, (defined $home ? (home => $home) : ()));
my $plan = $installer->run(
    dry_run => $dry_run,
    show_config => $show_config,
    no_debugger => $no_debugger,
    (defined $vim ? (vim => $vim) : ()),
    jdk => \@jdk,
);

if ($dry_run) {
    print "Dry run: no Vim files changed and no downloads performed.\n";
    print "Classic Vim: $plan->{vim}\n";
    print "Vim config: $plan->{vimrc}\nVim home: $plan->{vim_home}\n";
    print "Detected JDKs: ", (@{ $plan->{jdks} } ? join(', ', map { 'JavaSE-' . Vim::Tools::Java::Jdk::runtime_name($_->{major}) . '=' . $_->{home} } @{ $plan->{jdks} }) : 'none'), "\n";
    print "Java debugging: ", ($plan->{debugger} ? 'enabled (Vimspector + coc-java-debug)' : 'disabled (requires Vim +python3 and Python 3.10+ on non-Windows)'), "\n";
    print "AI assistant: $plan->{ai_provider} CLI", (defined $plan->{ai_cli} ? " ($plan->{ai_cli})" : ' (not found)'), "\n";
    print "Node.js: ", ($plan->{node_version} // 'not found'), "\n";
    print "Missing installation prerequisites: ", (@{ $plan->{missing} } ? join(', ', @{ $plan->{missing} }) : 'none'), "\n";
    print "\nManaged vimrc block:\n$plan->{vimrc_block}" if $show_config;
    exit 0;
}

print "Installed Java tooling in classic Vim at $plan->{vim_home}.\n";
print "AI completion is configured for the $plan->{ai_provider} CLI.\n";
print "Java debugging was omitted because Vim needs +python3 and Python 3.10+.\n" unless $plan->{debugger};
print "No local JDK was detected; provide one with --jdk VERSION=PATH.\n" unless @{ $plan->{jdks} };

sub usage {
    my ($status) = @_;
    print <<'HELP';
Usage: setup.pl [options]

Install Java editing and project tools for classic Vim. Run this script from
any working directory; it locates its modules and assets relative to itself.

  --dry-run          Inspect the installation plan without writes/downloads
  --show-config      Include the generated Vim configuration in a dry run
  --vim PATH         Select a classic Vim executable
  --home PATH        Install into this user's home directory (also useful in tests)
  --jdk VERSION=PATH Add/override a JDK; repeat it for multiple JDKs (version may be 21 or 21.0.1)
  --no-debugger      Omit Vimspector and coc-java-debug
  VIM_AI_WITH        Select copilot, codex, or claude in the project .env (default: copilot)
  --help             Show this help

Requires classic Vim 9.0.0438+ with +job, +channel, +terminal, and +timers, Node.js 22.15.0+,
git, and curl or wget. Java debugging also requires Vim +python3 and Python
3.10+. coc-java bundles its Java language server runtime on supported platforms.
HELP
    exit $status;
}
