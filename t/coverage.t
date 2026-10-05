use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use lib 'lib';
use Vim::Tools::Java::Coverage qw(covered_lines_from_xml coverage_report_for);

my $root = tempdir(CLEANUP => 1);
my $source = File::Spec->catfile($root, 'src', 'main', 'java', 'com', 'acme', 'Thing.java');
my $dir = File::Spec->catpath((File::Spec->splitpath($source))[0,1]);
make_path($dir);
open my $fh, '>', $source or die $!;
print {$fh} "class Thing {}\n";
close $fh;
open my $pom, '>', File::Spec->catfile($root, 'pom.xml') or die $!;
print {$pom} '<project />';
close $pom;
my $xml = <<'XML';
<?xml version="1.0"?>
<report name="demo">
 <package name="com/acme">
  <sourcefile name="Thing.java">
   <line nr="3" mi="0" ci="4" mb="0" cb="0"/>
   <line nr="4" mi="1" ci="0" mb="0" cb="0"/>
   <line nr="8" mi="2" ci="3" mb="0" cb="0"/>
  </sourcefile>
 </package>
</report>
XML
is_deeply(covered_lines_from_xml($xml, $source, $root), [3, 8], 'JaCoCo covered lines are returned for matching package and source');
is_deeply(covered_lines_from_xml($xml, File::Spec->catfile($root, 'Other.java'), $root), [], 'unmatched source has no coverage lines');

my $report = File::Spec->catfile($root, 'target', 'site', 'jacoco', 'jacoco.xml');
make_path(File::Spec->catpath((File::Spec->splitpath($report))[0,1]));
open my $report_fh, '>', $report or die $!;
print {$report_fh} $xml;
close $report_fh;
is_deeply(coverage_report_for($source), [3, 8], 'JaCoCo report is located from a source file');

my $untracked_root = tempdir(CLEANUP => 1);
my $untracked_source = File::Spec->catfile($untracked_root, 'Thing.java');
is(coverage_report_for($untracked_source), undef, 'source outside a project has no coverage report');

my $no_report_root = tempdir(CLEANUP => 1);
open my $marker, '>', File::Spec->catfile($no_report_root, 'pom.xml') or die $!;
close $marker;
my $no_report_source = File::Spec->catfile($no_report_root, 'Thing.java');
is(coverage_report_for($no_report_source), undef, 'project without a readable JaCoCo report has no coverage data');

done_testing;
