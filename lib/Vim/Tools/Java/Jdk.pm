package Vim::Tools::Java::Jdk;

use strict;
use warnings;
use Exporter qw(import);
use File::Basename qw(dirname basename);
use File::Spec;
use Cwd qw(abs_path);
use JSON::PP ();
use IPC::Open3 qw(open3);
use IO::Select;
use Symbol qw(gensym);

our @EXPORT_OK = qw(major_version discover_jdks runtime_name runtime_settings version_from_dir version_from_release);

sub major_version {
    my ($value) = @_;
    return unless defined $value;
    return 8 if $value =~ /^1\.8(?:\.|$)/;
    return 8 if $value =~ /^8(?:\.|$)/;
    return int($1) if $value =~ /^([0-9]+)/;
    return;
}

sub version_from_dir {
    my ($text) = @_;
    return 8 if $text =~ /(?:^|[-_])(?:1\.)?8(?:[._-]|$)/ || $text =~ /java-8/i;
    return int($1) if $text =~ /(?:^|[-_])((?:1[1-9]|[2-9][0-9]))(?:[._-]|$)/;
    return;
}

sub version_from_release {
    my ($dir) = @_;
    my $file = File::Spec->catfile($dir, 'release');
    return unless -r $file;
    open my $fh, '<', $file or return;
    local $/;
    my $text = <$fh> // '';
    return 8 if $text =~ /^JAVA_VERSION="1\.8/m;
    return int($1) if $text =~ /^JAVA_VERSION="([0-9]+)/m;
    return;
}

sub discover_jdks {
    my (%args) = @_;
    my $home = $args{home} // $ENV{HOME} // $ENV{USERPROFILE} // '';
    my $windows = $args{windows} // ($^O eq 'MSWin32');
    my $java_name = $windows ? 'java.exe' : 'java';
    my @roots = grep { defined && length } ($args{java_home} // $ENV{JAVA_HOME});
    my $path = $args{path} // $ENV{PATH} // '';
    my $path_java = _java_home_from_path($path, $windows);
    push @roots, $path_java if defined $path_java;
    push @roots, File::Spec->catdir($home, '.sdkman', 'candidates', 'java') if length($home) && !$windows;
    my %found;
    for my $root (@roots) {
        if (-x File::Spec->catfile($root, 'bin', $java_name)) {
            my $major = version_from_dir($root) // version_from_release($root);
            $found{$major} //= abs_path($root) || $root if $major;
            next;
        }
        next unless -d $root;
        opendir my $dh, $root or next;
        for my $entry (readdir $dh) {
            next if $entry =~ /^(?:\.|current$)/;
            my $path = File::Spec->catdir($root, $entry);
            next unless -x File::Spec->catfile($path, 'bin', $java_name);
            my $major = version_from_dir($entry) // version_from_release($path);
            $found{$major} //= abs_path($path) || $path if $major;
        }
        closedir $dh;
    }
    return [ map { { major => 0 + $_, home => $found{$_} } } sort { $a <=> $b } keys %found ];
}

sub _java_home_from_path {
    my ($path, $windows) = @_;
    my $name = $windows ? 'java.exe' : 'java';
    my $separator = $windows ? ';' : ':';
    my $binary;
    for my $dir (split(/\Q$separator\E/, $path)) {
        my $candidate = File::Spec->catfile(length($dir) ? $dir : '.', $name);
        if (-f $candidate && -x $candidate) {
            $binary = $candidate;
            last;
        }
    }
    return unless $binary;

    my $error = gensym;
    my ($pid, $stdout);
    eval { $pid = open3(undef, $stdout, $error, $binary, '-XshowSettings:properties', '-version') };
    return unless $pid;
    my $select = IO::Select->new($stdout, $error);
    my $output = '';
    while ($select->count) {
        for my $fh ($select->can_read) {
            my $count = sysread($fh, my $chunk, 4096);
            if (defined($count) && $count > 0) { $output .= $chunk }
            else { $select->remove($fh); close $fh }
        }
    }
    waitpid($pid, 0);
    my ($home) = $output =~ /^\s*java\.home\s*=\s*(.+?)\s*$/m;
    return unless defined $home && -d $home;
    return abs_path($home) || $home;
}

sub runtime_name { $_[0] == 8 ? '1.8' : $_[0] }

sub runtime_settings {
    my ($jdks) = @_;
    my $default;
    ($default) = grep { $_->{major} == 8 } @$jdks;
    ($default) = sort { $b->{major} <=> $a->{major} } @$jdks unless $default;
    return [ map {
        +{
            name    => 'JavaSE-' . runtime_name($_->{major}),
            path    => $_->{home},
            default => ($default && $_->{major} == $default->{major}) ? JSON::PP::true : JSON::PP::false,
        }
    } @$jdks ];
}

1;
