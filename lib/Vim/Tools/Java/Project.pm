package Vim::Tools::Java::Project;

use strict;
use warnings;
use Exporter qw(import);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Spec;
use Cwd qw(abs_path);
use Vim::Tools::Java::Jdk qw(discover_jdks major_version);

our @EXPORT_OK = qw(find_root find_module_root test_file_for java_class java_method test_plan);

sub find_root {
    my ($start) = @_;
    my $dir = -d $start ? $start : dirname($start);
    $dir = abs_path($dir) || $dir;
    while (1) {
        for my $marker (qw(.git mvnw gradlew pom.xml build.gradle build.gradle.kts)) {
            return $dir if -e File::Spec->catfile($dir, $marker);
        }
        my $parent = dirname($dir);
        return unless $parent ne $dir;
        $dir = $parent;
    }
}

sub find_module_root {
    my ($file, $outer) = @_;
    my $dir = -d $file ? $file : dirname($file);
    $dir = abs_path($dir) || $dir;
    my $outer_abs = defined($outer) ? (abs_path($outer) || $outer) : undef;
    while (1) {
        return $dir if -f File::Spec->catfile($dir, 'pom.xml');
        last if defined($outer_abs) && $dir eq $outer_abs;
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    return;
}

sub java_class {
    my ($file) = @_;
    open my $fh, '<', $file or return;
    while (my $line = <$fh>) {
        return $1 if $line =~ /\b(?:class|interface|enum|record)\s+([A-Za-z_\$][\w\$]*)/;
    }
    return (basename($file) =~ /^(.*)\.java$/)[0];
}

sub java_method {
    my ($file, $line_number) = @_;
    open my $fh, '<', $file or return;
    my @lines = <$fh>;
    my $limit = defined($line_number) && $line_number > 0 ? $line_number : scalar @lines;
    $limit = @lines if $limit > @lines;
    for (my $i = $limit - 1; $i >= 0; $i--) {
        my $line = $lines[$i];
        next if $line =~ /^\s*(?:@|\/\*|\*|\/\/|class\b|interface\b|enum\b|record\b)/;
        # Java method declarations used by JUnit and ordinary source methods.
        if ($line =~ /^\s*(?:(?:public|protected|private|static|final|synchronized|abstract|native|default|strictfp)\s+)*(?:<[^>]+>\s*)?[\w.\$<>\[\], ?]+\s+([A-Za-z_\$][\w\$]*)\s*\([^;]*\)\s*(?:throws\b[^\{]+)?\s*(?:\{.*)?$/) {
            my $name = $1;
            return $name unless $name eq 'if' || $name eq 'for' || $name eq 'while' || $name eq 'switch' || $name eq 'catch' || $name eq 'return';
        }
    }
    return;
}

sub test_file_for {
    my ($file, $project_root) = @_;
    my $absolute = abs_path($file) || $file;
    if ($absolute =~ m{[/\\]src[/\\]test[/\\]java[/\\]}) {
        return -f $absolute ? $absolute : undef;
    }
    my @candidate_paths;
    if ($absolute =~ m{^(.*?)[/\\]src[/\\]main[/\\]java[/\\](.*)\.java$}) {
        my ($base, $relative) = ($1, $2);
        for my $suffix (qw(Test Tests IT)) {
            my $candidate = File::Spec->catfile($base, 'src', 'test', 'java', split(m{[/\\]}, "$relative$suffix.java"));
            push @candidate_paths, $candidate if -f $candidate;
        }
    }
    return $candidate_paths[0] if @candidate_paths;

    my $root = $project_root || find_root($file) || dirname($file);
    my $class = java_class($file) || basename($file, '.java');
    my @matches;
    find({
        wanted => sub {
            if (-d $_ && basename($_) =~ /^(?:\.git|target|build|out|node_modules)$/) {
                $File::Find::prune = 1;
                return;
            }
            return unless -f $_ && basename($_) =~ /^(?:\Q$class\E)(?:Test|Tests|IT)?\.java$/;
            return unless $File::Find::dir =~ m{(?:^|[/\\])src[/\\]test[/\\]java(?:[/\\]|$)};
            push @matches, $File::Find::name;
        },
        no_chdir => 1,
    }, $root);
    @matches = sort @matches;
    return $matches[0];
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    return <$fh> // '';
}

sub _java_release_from_pom {
    my ($pom) = @_;
    my %props;
    my @poms;
    my $dir = dirname($pom);
    while (1) {
        my $candidate = File::Spec->catfile($dir, 'pom.xml');
        unshift @poms, $candidate if -r $candidate;
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    for my $path (@poms) {
        my $xml = _read_file($path);
        $xml =~ s/<!--.*?-->//sg;
        while ($xml =~ m{<properties\b[^>]*>(.*?)</properties>}sg) {
            my $section = $1;
            while ($section =~ m{<([\w.-]+)>\s*([^<]+?)\s*</\1>}sg) {
                $props{$1} = $2;
            }
        }
        while ($xml =~ m{<(maven\.compiler\.(?:release|source|target)|java\.version)>\s*([^<]+?)\s*</\1>}sg) {
            $props{$1} = $2;
        }
    }
    for my $tag (qw(maven.compiler.release maven.compiler.source maven.compiler.target java.version)) {
        my $v = $props{$tag};
        next unless defined $v;
        $v =~ s/^\s+|\s+$//g;
        $v = $props{$1} if $v =~ /^\$\{([^}]+)\}$/ && exists $props{$1};
        my $major = major_version($v);
        return $major if $major;
    }
    return 8;
}

sub _sdk_for_release {
    my ($release, $env) = @_;
    my $home = $env->{HOME} // $ENV{HOME} // '';
    my $jdks = discover_jdks(home => $home, java_home => $env->{JAVA_HOME}, path => $env->{PATH});
    my ($match) = grep { $_->{major} == $release } @$jdks;
    return $match->{home} if $match;
    return $env->{JAVA_HOME} if $env->{JAVA_HOME};
    return;
}

sub test_plan {
    my (%args) = @_;
    my $file = $args{file} or die "test_plan requires file\n";
    my $kind = $args{kind} // 'nearest';
    my $line = $args{line} // 0;
    my $outer = find_root($file) or die "No Maven or Gradle project root found from $file\n";
    my $test_file = test_file_for($file, $outer) or die "No corresponding Java test file found for $file\n";
    my $module = find_module_root($test_file, $outer) || find_module_root($file, $outer) || $outer;
    my $class = java_class($test_file) or die "Cannot determine Java test class from $test_file\n";
    my $selector = $class;
    if ($kind eq 'nearest') {
        my $method = $file eq $test_file ? java_method($test_file, $line) : java_method($file, $line);
        $selector .= "#$method" if $method;
    } elsif ($kind ne 'file') {
        die "Unknown test kind '$kind'\n";
    }
    my $pom = File::Spec->catfile($module, 'pom.xml');
    -f $pom or die "Java test runner currently requires Maven pom.xml in $module\n";
    my $release = _java_release_from_pom($pom);
    my $jdk = _sdk_for_release($release, $args{env} || {});
    my $mvnw = File::Spec->catfile($module, ($^O eq 'MSWin32' ? 'mvnw.cmd' : 'mvnw'));
    my $maven = (-x $mvnw || ($^O eq 'MSWin32' && -f $mvnw)) ? $mvnw : 'mvn';
    my @argv = ($maven, "-Dtest=$selector");
    push @argv, '-Dmaven.surefire.debug' if $args{debug};
    push @argv, 'test';
    my %environment;
    $environment{JAVA_HOME} = $jdk if defined $jdk;
    $environment{PATH} = File::Spec->catdir($jdk, 'bin') . ($^O eq 'MSWin32' ? ';' : ':') . ($args{env}{PATH} // $ENV{PATH} // '') if defined $jdk;
    return {
        cwd => $module,
        argv => \@argv,
        env => \%environment,
        selector => $selector,
        java_release => $release,
        java_home => $jdk,
        test_file => $test_file,
        debug_port => $args{debug} ? 5005 : undef,
    };
}

1;
