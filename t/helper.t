use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);
use JSON::PP qw(decode_json);

my $tmp = tempdir(CLEANUP => 1);
my $root = File::Spec->catdir($tmp, 'project');
my $main = File::Spec->catfile($root, 'src', 'main', 'java', 'demo', 'Widget.java');
my $test = File::Spec->catfile($root, 'src', 'test', 'java', 'demo', 'WidgetTest.java');
make_path(dirname($main), dirname($test), File::Spec->catdir($root, '.git'));
write_file(File::Spec->catfile($root, 'pom.xml'), '<project/>');
write_file($main, "package demo;\nclass Widget {}\n");
write_file($test, "package demo;\nclass WidgetTest {}\n");

my $helper = File::Spec->catfile(File::Spec->rel2abs('.'), 'assets', 'vim', 'bin', 'java-project.pl');
my ($status, $output) = run_helper($helper, 'find-test', '--file', $main);
is($status, 0, 'asset helper runs directly from the source checkout');
is($output, abs_path($test) . "\n", 'helper resolves production source to its test file');

($status, $output) = run_helper($helper, 'plan', '--file', $test, '--line', 2, '--kind', 'file', '--debug');
is($status, 0, 'plan command accepts a Java test request');
my $plan = decode_json($output);
is($plan->{selector}, 'WidgetTest', 'plan command returns the test class selector');
is($plan->{debug_port}, 5005, 'plan command returns the debug port');

my $report = File::Spec->catfile($root, 'target', 'site', 'jacoco', 'jacoco.xml');
make_path(dirname($report));
write_file($report, '<report><package name="demo"><sourcefile name="Widget.java"><line nr="4" ci="1"/></sourcefile></package></report>');
($status, $output) = run_helper($helper, 'coverage', $main);
is($status, 0, 'coverage command accepts a source path');
is_deeply(decode_json($output), [4], 'coverage command emits JaCoCo covered line numbers');

make_path(File::Spec->catdir($root, 'lib', 'Foo'));
write_file(File::Spec->catfile($root, 'lib', 'Foo', 'Bar.pm'), "package Foo::Bar;\n1;\n");
($status, $output) = run_helper($helper, 'resolve-module', '--line', 'use Foo::Bar;', '--column', 8, '--cwd', $root);
is($status, 0, 'resolve-module command accepts a Perl module reference');
is($output, abs_path(File::Spec->catfile($root, 'lib', 'Foo', 'Bar.pm')) . "\n", 'resolve-module prints the module path');

($status) = run_helper($helper, 'invalid-action');
ok($status != 0, 'unknown helper actions are rejected');
($status) = run_helper($helper, 'coverage');
ok($status != 0, 'coverage requires a source path');
($status) = run_helper($helper, 'plan', '--invalid');
ok($status != 0, 'plan rejects unknown options');
($status) = run_helper($helper, 'find-test', '--invalid');
ok($status != 0, 'find-test rejects unknown options');
($status) = run_helper($helper, 'resolve-module', '--invalid');
ok($status != 0, 'resolve-module rejects unknown options');

sub write_file {
    my ($path, $content) = @_;
    open my $out, '>', $path or die "Cannot write $path: $!";
    print {$out} $content;
    close $out;
}

sub run_helper {
    my ($helper, @args) = @_;
    open my $fh, '-|', $^X, $helper, @args or die "Cannot launch Java helper: $!";
    local $/;
    my $output = <$fh> // '';
    close $fh;
    return ($? >> 8, $output);
}

done_testing;
