use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Spec;
use lib 'lib';
use Vim::Tools::Java::Project qw(find_root find_module_root test_file_for java_class java_method test_plan);

my $home = tempdir(CLEANUP => 1);
my $root = File::Spec->catdir($home, 'demo');
my $main = File::Spec->catfile($root, 'src', 'main', 'java', 'com', 'acme', 'Thing.java');
my $test = File::Spec->catfile($root, 'src', 'test', 'java', 'com', 'acme', 'ThingTest.java');
make_path(dirname($main), dirname($test), File::Spec->catdir($root, '.git'));
write_file(File::Spec->catfile($root, 'pom.xml'), <<'XML');
<project><properties><java.version>17</java.version></properties></project>
XML
write_file($main, <<'JAVA');
package com.acme;
public class Thing {
  public void works() {
    System.out.println("ok");
  }
}
JAVA
write_file($test, <<'JAVA');
package com.acme;
public class ThingTest {
  @Test
  public void works() {
    assertTrue(true);
  }
  @Test
  public void another() { }
}
JAVA

is(find_root($main), abs_path($root), 'project root is located from source file');
is(find_module_root($test, $root), abs_path($root), 'nearest Maven module is selected');
is(test_file_for($main, $root), abs_path($test), 'production Java path maps to mirrored test source');
is(test_file_for($test, $root), abs_path($test), 'test file resolves to itself');
is(java_class($test), 'ThingTest', 'top-level test class is extracted');
is(java_method($test, 4), 'works', 'nearest declared Java method is extracted');
is(java_method($test, 8), 'another', 'later method is selected for its line');

my $sdkman = File::Spec->catdir($home, '.sdkman', 'candidates', 'java');
my $jdk = File::Spec->catdir($sdkman, '17.0.10-tem');
make_path(File::Spec->catdir($jdk, 'bin'));
write_file(File::Spec->catfile($jdk, 'bin', 'java'), '');
chmod 0755, File::Spec->catfile($jdk, 'bin', 'java');
my $plan = test_plan(file => $test, line => 4, kind => 'nearest', env => { HOME => $home, PATH => '/usr/bin' });
is($plan->{selector}, 'ThingTest#works', 'nearest test targets class and method');
is($plan->{java_release}, 17, 'POM project Java release is read');
is($plan->{java_home}, abs_path($jdk), 'matching SDKMAN JDK is selected for Maven');
is_deeply($plan->{argv}, ['mvn', '-Dtest=ThingTest#works', 'test'], 'Maven invocation matches class and method selector');

my $file_plan = test_plan(file => $test, line => 4, kind => 'file', env => { HOME => $home, PATH => '/usr/bin' });
is($file_plan->{selector}, 'ThingTest', 'file test targets entire class');
my $debug_plan = test_plan(file => $test, line => 4, kind => 'nearest', debug => 1, env => { HOME => $home, PATH => '/usr/bin' });
is_deeply($debug_plan->{argv}, ['mvn', '-Dtest=ThingTest#works', '-Dmaven.surefire.debug', 'test'], 'test debugging suspends the selected test for an attach session');

my $module = File::Spec->catdir($root, 'service');
my $module_main = File::Spec->catfile($module, 'src', 'main', 'java', 'com', 'acme', 'Service.java');
my $module_test = File::Spec->catfile($module, 'src', 'test', 'java', 'com', 'acme', 'ServiceTest.java');
make_path(dirname($module_main), dirname($module_test));
write_file(File::Spec->catfile($module, 'pom.xml'), '<project><parent><relativePath>../pom.xml</relativePath></parent></project>');
write_file($module_main, "package com.acme;\npublic class Service {}\n");
write_file($module_test, "package com.acme;\npublic class ServiceTest {}\n");
my $wrapper = File::Spec->catfile($module, 'mvnw');
write_file($wrapper, "#!/bin/sh\nexit 0\n");
chmod 0755, $wrapper;
my $inherited = test_plan(file => $module_test, line => 2, kind => 'file', env => { HOME => $home, PATH => '/usr/bin' });
is($inherited->{cwd}, abs_path($module), 'nested Maven module is the test working directory');
is($inherited->{java_release}, 17, 'Java version is inherited from parent POM');
is($inherited->{argv}[0], abs_path($wrapper), 'module Maven wrapper is preferred when present');
is($inherited->{selector}, 'ServiceTest', 'nested module test class is resolved');

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}
done_testing;
