use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use lib 'lib';
use Vim::Tools::Java::Jdk qw(major_version discover_jdks runtime_name runtime_settings version_from_dir version_from_release);

is(major_version('1.8.0_402'), 8, 'legacy Java 8 version parses');
is(major_version('8.0.482'), 8, 'SDKMAN Java 8 version parses');
is(major_version('21.0.10'), 21, 'modern Java version parses');
is(major_version('not-java'), undef, 'invalid Java version is rejected');
is(version_from_dir('8.0.402-amzn'), 8, 'SDKMAN Java 8 directory parses');
is(version_from_dir('21.0.10-tem'), 21, 'SDKMAN Java 21 directory parses');
is(runtime_name(8), '1.8', 'Eclipse execution environment uses JavaSE-1.8 naming');

my $tmp = tempdir(CLEANUP => 1);
my $jdk8 = File::Spec->catdir($tmp, 'jdk-8');
make_path(File::Spec->catdir($jdk8, 'bin'));
open my $java, '>', File::Spec->catfile($jdk8, 'bin', 'java') or die $!;
close $java;
chmod 0755, File::Spec->catfile($jdk8, 'bin', 'java');
open my $release, '>', File::Spec->catfile($jdk8, 'release') or die $!;
print {$release} "JAVA_VERSION=\"1.8.0_402\"\n";
close $release;
is(version_from_release($jdk8), 8, 'release metadata identifies Java 8');
my $sdkman8 = File::Spec->catdir($tmp, '.sdkman', 'candidates', 'java', '8.0.999-test');
make_path(File::Spec->catdir($sdkman8, 'bin'));
open my $sdkjava, '>', File::Spec->catfile($sdkman8, 'bin', 'java') or die $!;
close $sdkjava;
chmod 0755, File::Spec->catfile($sdkman8, 'bin', 'java');
my $discovered = discover_jdks(home => $tmp, java_home => $jdk8);
is($discovered->[0]{home}, abs_path($jdk8), 'JAVA_HOME takes priority over SDKMAN of the same major');

my $path_bin = File::Spec->catdir($tmp, 'path-bin');
my $path_home = File::Spec->catdir($tmp, 'path-jdk');
make_path($path_bin, File::Spec->catdir($path_home, 'bin'));
open my $path_java, '>', File::Spec->catfile($path_bin, 'java') or die $!;
print {$path_java} "#!/bin/sh\necho '    java.home = $path_home' >&2\n";
close $path_java;
chmod 0755, File::Spec->catfile($path_bin, 'java');
open my $path_java_bin, '>', File::Spec->catfile($path_home, 'bin', 'java') or die $!;
close $path_java_bin;
chmod 0755, File::Spec->catfile($path_home, 'bin', 'java');
open my $path_release, '>', File::Spec->catfile($path_home, 'release') or die $!;
print {$path_release} "JAVA_VERSION=\"21.0.1\"\n";
close $path_release;
my $from_path = discover_jdks(home => $tmp, path => $path_bin);
my ($java21) = grep { $_->{major} == 21 } @$from_path;
is($java21->{home}, abs_path($path_home), 'JDK exposed only on PATH is resolved through java.home');

my $jdks = [
    { major => 8, home => '/jdk/8' },
    { major => 21, home => '/jdk/21' },
];
my $settings = runtime_settings($jdks);
is($settings->[0]{name}, 'JavaSE-1.8', 'runtime settings include Java 8');
ok($settings->[0]{default}, 'Java 8 is the default when available, matching hov1');
ok(!$settings->[1]{default}, 'other JDK is not marked default');

done_testing;
