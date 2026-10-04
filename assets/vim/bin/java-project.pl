#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../perl5", "$FindBin::Bin/../../../lib";
use JSON::PP qw(encode_json);
use Getopt::Long qw(GetOptionsFromArray);
use Vim::Tools::Java::Project qw(test_plan test_file_for);
use Vim::Tools::Java::Coverage qw(coverage_report_for);
use Vim::Tools::Perl::ModuleLookup qw(module_at_position resolve_module);

my $action = shift @ARGV // '';
if ($action eq 'plan') {
    my ($file, $line, $kind, $debug) = ('', 0, 'nearest', 0);
    GetOptionsFromArray(\@ARGV, 'file=s' => \$file, 'line=i' => \$line, 'kind=s' => \$kind, 'debug!' => \$debug)
      or die "Invalid plan arguments\n";
    print encode_json(test_plan(file => $file, line => $line, kind => $kind, debug => $debug, env => \%ENV));
} elsif ($action eq 'find-test') {
    my ($file, $root) = ('', undef);
    GetOptionsFromArray(\@ARGV, 'file=s' => \$file, 'root=s' => \$root)
      or die "Invalid find-test arguments\n";
    my $test = test_file_for($file, $root) or die "No related test source found for $file\n";
    print "$test\n";
} elsif ($action eq 'coverage') {
    my ($file) = @ARGV;
    defined $file or die "coverage requires a Java source file\n";
    print encode_json(coverage_report_for($file) || []);
} elsif ($action eq 'resolve-module') {
    my ($line, $column, $cwd) = ('', 1, '.');
    GetOptionsFromArray(\@ARGV, 'line=s' => \$line, 'column=i' => \$column, 'cwd=s' => \$cwd)
      or die "Invalid resolve-module arguments\n";
    my $module = module_at_position(line => $line, column => $column)
      or die "No Perl module name under cursor\n";
    my $path = resolve_module(module => $module, cwd => $cwd)
      or die "Perl module $module not found in $cwd/lib or this Perl's \@INC\n";
    print "$path\n";
} else {
    die "Usage: java-project.pl plan --file FILE --line N [--kind nearest|file] [--debug]\n       java-project.pl find-test --file FILE\n       java-project.pl coverage FILE\n       java-project.pl resolve-module --line TEXT --column N --cwd DIR\n";
}
