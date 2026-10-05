use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use lib 'lib';
use Vim::Tools::AI::Config qw(ai_provider);

my $root = tempdir(CLEANUP => 1);
is(ai_provider(root => $root, env => {}), 'copilot', 'Copilot CLI is the default provider');

my $env_file = File::Spec->catfile($root, '.env');
open my $env, '>', $env_file or die "Cannot create test .env: $!";
print {$env} "VERSION=1.0\nVIM_AI_WITH=codex # selected provider\n";
close $env;
is(ai_provider(root => $root, env => {}), 'codex', 'provider is read from project .env');
is(ai_provider(root => $root, env => { VIM_AI_WITH => 'claude' }), 'claude', 'environment value overrides .env');

open $env, '>', $env_file or die "Cannot rewrite test .env: $!";
print {$env} "VIM_AI_WITH=\"CoDeX\" # quoted selection\n";
close $env;
is(ai_provider(root => $root, env => {}), 'codex', 'quoted provider names are normalized');

open $env, '>', $env_file or die "Cannot rewrite test .env: $!";
print {$env} "VIM_AI_WITH=gemini\n";
close $env;
my $ok = eval { ai_provider(root => $root, env => {}); 1 };
ok(!$ok && $@ =~ /choose copilot, codex, or claude/, 'unsupported provider is rejected');

done_testing;
