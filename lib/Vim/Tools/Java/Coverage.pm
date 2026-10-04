package Vim::Tools::Java::Coverage;

use strict;
use warnings;
use Exporter qw(import);
use File::Basename qw(basename);
use File::Spec;
use Vim::Tools::Java::Project qw(find_root find_module_root);

our @EXPORT_OK = qw(covered_lines_from_xml coverage_report_for);

sub covered_lines_from_xml {
    my ($xml, $file, $module_root) = @_;
    my @result;
    my $wanted = basename($file);
    while ($xml =~ m{<package\s+name="([^"]*)"[^>]*>(.*?)</package>}sg) {
        my ($package, $body) = ($1, $2);
        while ($body =~ m{<sourcefile\s+name="([^"]+)"[^>]*>(.*?)</sourcefile>}sg) {
            my ($name, $section) = ($1, $2);
            next unless $name eq $wanted;
            my $expected = File::Spec->catfile($module_root, 'src', 'main', 'java', split('/', $package), $wanted);
            next unless _same_path($expected, $file);
            while ($section =~ m{<line\s+[^>]*nr="(\d+)"[^>]*ci="(\d+)"[^>]*/>}g) {
                push @result, 0 + $1 if $2 > 0;
            }
            return \@result;
        }
    }
    return \@result;
}

sub coverage_report_for {
    my ($source) = @_;
    my $root = find_root($source) or return;
    my $module = find_module_root($source, $root) || $root;
    my $report = File::Spec->catfile($module, 'target', 'site', 'jacoco', 'jacoco.xml');
    return unless -r $report;
    open my $fh, '<', $report or return;
    local $/;
    my $xml = <$fh> // '';
    return covered_lines_from_xml($xml, $source, $module);
}

sub _same_path {
    my ($left, $right) = @_;
    require Cwd;
    return (Cwd::abs_path($left) || File::Spec->canonpath($left)) eq
           (Cwd::abs_path($right) || File::Spec->canonpath($right));
}

1;
