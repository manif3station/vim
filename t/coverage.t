use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use lib 'lib';
use Vim::Tools::Java::Coverage qw(covered_lines_from_xml);

my $root = tempdir(CLEANUP => 1);
my $source = File::Spec->catfile($root, 'src', 'main', 'java', 'com', 'acme', 'Thing.java');
my $dir = File::Spec->catpath((File::Spec->splitpath($source))[0,1]);
make_path($dir);
open my $fh, '>', $source or die $!;
print {$fh} "class Thing {}\n";
close $fh;
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

done_testing;
