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
my $orphan = tempdir(CLEANUP => 1);
is(find_root(File::Spec->catfile($orphan, 'Orphan.java')), undef, 'file without a project marker has no root');
is(find_module_root(File::Spec->catfile($orphan, 'Orphan.java'), $orphan), undef, 'directory without a Maven module has no module root');
is(test_file_for($main, $root), abs_path($test), 'production Java path maps to mirrored test source');
is(test_file_for($test, $root), abs_path($test), 'test file resolves to itself');
is(java_class($test), 'ThingTest', 'top-level test class is extracted');
is(java_method($test, 4), 'works', 'nearest declared Java method is extracted');
is(java_method($test, 8), 'another', 'later method is selected for its line');

my $secondary = File::Spec->catfile($root, 'src', 'main', 'java', 'com', 'acme', 'Secondary.java');
write_file($secondary, "package com.acme;\n");
is(java_class($secondary), 'Secondary', 'source filename supplies the class name when no declaration is found');
is(java_method($secondary, 1), undef, 'source with no method declaration returns no method name');
my $secondary_test = File::Spec->catfile($root, 'fixtures', 'src', 'test', 'java', 'com', 'acme', 'SecondaryTest.java');
my $secondary_wrong_location = File::Spec->catfile($root, 'fixtures', 'src', 'main', 'java', 'com', 'acme', 'SecondaryTest.java');
my $secondary_pruned = File::Spec->catfile($root, 'target', 'src', 'test', 'java', 'com', 'acme', 'SecondaryTest.java');
make_path(dirname($secondary_test), dirname($secondary_wrong_location), dirname($secondary_pruned));
write_file($secondary_test, "class SecondaryTest {}\n");
write_file($secondary_wrong_location, "class SecondaryTest {}\n");
write_file($secondary_pruned, "class SecondaryTest {}\n");
is(test_file_for($secondary, $root), $secondary_test, 'fallback search finds tests outside the mirrored source layout');
my $missing_source = File::Spec->catfile($root, 'src', 'main', 'java', 'com', 'acme', 'Missing.java');
write_file($missing_source, "class Missing {}\n");
is(test_file_for($missing_source, $root), undef, 'fallback search returns undef when no test exists');

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

my $default_root = File::Spec->catdir($home, 'default-java');
my $default_main = File::Spec->catfile($default_root, 'src', 'main', 'java', 'DefaultThing.java');
my $default_test = File::Spec->catfile($default_root, 'src', 'test', 'java', 'DefaultThingTest.java');
make_path(dirname($default_main), dirname($default_test));
write_file(File::Spec->catfile($default_root, 'pom.xml'), '<project />');
write_file($default_main, "class DefaultThing {}\n");
write_file($default_test, "class DefaultThingTest {}\n");
my $default_plan = test_plan(file => $default_main, kind => 'file', env => { HOME => $orphan, PATH => '' });
is($default_plan->{java_release}, 8, 'Maven projects without a configured release default to Java 8');
is($default_plan->{java_home}, undef, 'test plans omit JAVA_HOME when no matching JDK exists');
my $unknown_kind = eval { test_plan(file => $test, kind => 'suite', env => { HOME => $home, PATH => '/usr/bin' }); 1 };
ok(!$unknown_kind && $@ =~ /Unknown test kind/, 'unknown test selection kinds are rejected');

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}
done_testing;
