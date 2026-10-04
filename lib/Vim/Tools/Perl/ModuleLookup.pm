package Vim::Tools::Perl::ModuleLookup;

use strict;
use warnings;
use Cwd qw(abs_path);
use Exporter 'import';
use File::Spec;

our @EXPORT_OK = qw(module_at_position resolve_module);

sub module_at_position {
    my (%args) = @_;
    my $line = $args{line} // '';
    my $column = $args{column} // 1; # Vim columns are one based.
    my @matches;
    while ($line =~ /(?:\b(?:use|require)\s+)?([A-Za-z_]\w*(?:(?:::|\/)[A-Za-z_]\w*)*(?:\.pm)?)/g) {
        my ($start, $end, $name) = ($-[1] + 1, $+[1], $1);
        push @matches, [$start, $end, $name];
    }
    for my $match (@matches) {
        return $match->[2] if $column >= $match->[0] && $column <= $match->[1];
    }
    return undef;
}

sub resolve_module {
    my (%args) = @_;
    my $name = $args{module} // '';
    return undef unless $name =~ /\A[A-Za-z_]\w*(?:(?:::|\/)[A-Za-z_]\w*)*(?:\.pm)?\z/;
    my $relative = $name;
    $relative =~ s!::!/!g;
    $relative .= '.pm' unless $relative =~ /\.pm\z/;
    my $cwd = $args{cwd} // '.';
    my @roots = (File::Spec->catdir($cwd, 'lib'));
    push @roots, @{$args{inc} // \@INC};
    for my $root (@roots) {
        next unless defined $root && length $root;
        $root = File::Spec->rel2abs($root, $cwd) unless File::Spec->file_name_is_absolute($root);
        my $candidate = File::Spec->catfile($root, split m!/!, $relative);
        return abs_path($candidate) if -f $candidate;
    }
    return undef;
}

1;
