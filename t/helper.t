use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

my $tmp = tempdir(CLEANUP => 1);
my $root = File::Spec->catdir($tmp, 'project');
my $main = File::Spec->catfile($root, 'src', 'main', 'java', 'demo', 'Widget.java');
my $test = File::Spec->catfile($root, 'src', 'test', 'java', 'demo', 'WidgetTest.java');
make_path(dirname($main), dirname($test), File::Spec->catdir($root, '.git'));
write_file(File::Spec->catfile($root, 'pom.xml'), '<project/>');
write_file($main, "package demo;\nclass Widget {}\n");
write_file($test, "package demo;\nclass WidgetTest {}\n");

my $helper = File::Spec->catfile(File::Spec->rel2abs('.'), 'assets', 'vim', 'bin', 'java-project.pl');
open my $fh, '-|', $^X, $helper, 'find-test', '--file', $main or die "Cannot launch Java helper: $!";
local $/;
my $output = <$fh> // '';
close $fh;
is($? >> 8, 0, 'asset helper runs directly from the source checkout');
is($output, abs_path($test) . "\n", 'helper resolves production source to its test file');

sub write_file {
    my ($path, $content) = @_;
    open my $out, '>', $path or die "Cannot write $path: $!";
    print {$out} $content;
    close $out;
}

done_testing;
