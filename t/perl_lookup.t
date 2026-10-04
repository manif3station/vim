use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use lib 'lib';
use Vim::Tools::Perl::ModuleLookup qw(module_at_position resolve_module);

my $module = module_at_position(line => 'use Foo::Bar qw(run);', column => 8);
is($module, 'Foo::Bar', 'finds a module name under cursor in use statement');
is(module_at_position(line => 'require Local/Thing.pm;', column => 14), 'Local/Thing.pm', 'finds slash module in require');

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/lib/Foo", "$dir/inc/Baz");
open my $local, '>', "$dir/lib/Foo/Bar.pm" or die $!;
close $local;
open my $inc, '>', "$dir/inc/Baz/Thing.pm" or die $!;
close $inc;
is(resolve_module(module => 'Foo::Bar', cwd => $dir, inc => ["$dir/inc"]), abs_path("$dir/lib/Foo/Bar.pm"), 'project lib takes precedence over @INC');
is(resolve_module(module => 'Baz::Thing', cwd => $dir, inc => ["$dir/inc"]), abs_path("$dir/inc/Baz/Thing.pm"), 'resolves modules on supplied @INC');
is(resolve_module(module => '../outside', cwd => $dir, inc => []), undef, 'rejects path traversal and invalid module names');

done_testing;
