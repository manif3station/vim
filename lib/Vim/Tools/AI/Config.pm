package Vim::Tools::AI::Config;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(ai_provider);

sub ai_provider {
    my (%args) = @_;
    my $env = $args{env} || {};
    my $value = $env->{VIM_AI_WITH};

    if (!defined $value) {
        my $path = "$args{root}/.env";
        if (open my $fh, '<', $path) {
            while (my $line = <$fh>) {
                next unless $line =~ /^\s*VIM_AI_WITH\s*=\s*(.*?)\s*$/;
                $value = $1;
                $value =~ s/\s+#.*$//;
                if ($value =~ /^(['"])(.*)\1$/) {
                    $value = $2;
                }
                last;
            }
            close $fh;
        }
    }

    $value = 'copilot' unless defined $value && length $value;
    $value = lc $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ /\A(?:copilot|codex|claude|fm|auto)\z/
      or die "Invalid VIM_AI_WITH '$value'; choose copilot, codex, or claude, or use fm or auto.\n";
    if ($value eq 'auto') {
        return $^O eq 'darwin' && _fm_available($env) ? 'fm' : 'copilot';
    }
    return $value;
}

sub _fm_available {
    my ($env) = @_;
    my $fm = '/usr/bin/fm';
    return 0 unless -x $fm;
    my $path = $env->{PATH} // $ENV{PATH} // '';
    return 0 unless grep { $_ eq '/usr/bin' } split /:/, $path;
    open my $fh, '-|', $fm, 'available' or return 0;
    my $output = do { local $/; <$fh> // '' };
    return close($fh) && $output =~ /^System model available\s*$/m;
}

1;
