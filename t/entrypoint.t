use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd);

my $old_cwd = getcwd();
my $home = tempdir(CLEANUP => 1);
my $script = File::Spec->catfile($old_cwd, 'cli', 'setup.pl');
chdir '/tmp' or die "Cannot chdir to /tmp: $!";
open my $fh, '-|', $^X, $script, '--dry-run', '--home', $home or die "Cannot launch installer: $!";
local $/;
my $output = <$fh> // '';
close $fh;
my $status = $? >> 8;
chdir $old_cwd or die "Cannot restore working directory: $!";

is($status, 0, 'installer runs successfully from outside its project directory');
like($output, qr/Classic Vim:/, 'dry-run reports classic Vim executable');
like($output, qr/\Q$home\E\/.vimrc/, 'dry-run uses the explicitly selected home');
ok(!-e File::Spec->catfile($home, '.vimrc'), 'dry-run creates no Vim config');
ok(!-e File::Spec->catdir($home, '.vim'), 'dry-run creates no Vim data directory');

done_testing;
