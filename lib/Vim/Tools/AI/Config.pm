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
    $value =~ /\A(?:copilot|codex|claude)\z/
      or die "Invalid VIM_AI_WITH '$value'; choose copilot, codex, or claude.\n";
    return $value;
}

1;
