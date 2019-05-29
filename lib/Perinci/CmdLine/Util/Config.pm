package Perinci::CmdLine::Util::Config;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Exporter qw(import);
our @EXPORT_OK = (
    'get_default_config_dirs',
    'read_config',
    'get_args_from_config',
);

our %SPEC;

# from PERLANCAR::File::HomeDir 0.03, with minor modification
sub _get_my_home_dir {
    if ($^O eq 'MSWin32') {
        # File::HomeDir always uses exists($ENV{x}) first, does it want to avoid
        # accidentally creating env vars?
        return $ENV{HOME} if $ENV{HOME};
        return $ENV{USERPROFILE} if $ENV{USERPROFILE};
        return join($ENV{HOMEDRIVE}, "\\", $ENV{HOMEPATH})
            if $ENV{HOMEDRIVE} && $ENV{HOMEPATH};
    } else {
        return $ENV{HOME} if $ENV{HOME};
        my @pw;
        eval { @pw = getpwuid($>) };
        return $pw[7] if @pw;
    }
    die "Can't get home directory";
}

$SPEC{get_default_config_dirs} = {
    v => 1.1,
    args => {},
};
sub get_default_config_dirs {
    my @dirs;
    #local $PERLANCAR::File::HomeDir::DIE_ON_FAILURE = 1;
    my $home = _get_my_home_dir();
    if ($^O eq 'MSWin32') {
        push @dirs, $home;
    } else {
        push @dirs, "$home/.config", $home, "/etc";
    }
    \@dirs;
}

$SPEC{read_config} = {
    v => 1.1,
    args => {
        config_paths    => {},
        config_filename => {},
        config_dirs     => {},
        program_name    => {},
        # TODO: hook_file
        hook_section    => {},
        # TODO: hook_param?
    },
};
sub read_config {
    require Config::IOD::Reader;

    my %args = @_;

    my $config_dirs = $args{config_dirs} // get_default_config_dirs();

    my $paths;

    my @filenames;
    my %section_config_filename_map;
    if (my $names = $args{config_filename}) {
        for my $name (ref($names) eq 'ARRAY' ? @$names : ($names)) {
            if (ref($name) eq 'HASH') {
                $section_config_filename_map{$name->{filename}} = $name->{section};
                push @filenames, $name->{filename};
            } else {
                $section_config_filename_map{$name} = 'GLOBAL';
                push @filenames, $name;
            }
        }
    }
    unless (@filenames) {
        @filenames = (($args{program_name} // "prog") . ".conf");
    }

    if ($args{config_paths}) {
        $paths = $args{config_paths};
    } else {
        for my $dir (@$config_dirs) {
            for my $name (@filenames) {
                my $path = "$dir/" . $name;
                push @$paths, $path if -e $path;
            }
        }
    }

    my $reader = Config::IOD::Reader->new;
    my %res;
    my @read;
    my %section_read_order;
  FILE:
    for my $i (0..$#{$paths}) {
        my $path           = $paths->[$i];
        my $filename = $path; $filename =~ s!.*[/\\]!!;
        my $wanted_section = $section_config_filename_map{$filename};
        log_trace "[pericmd] Reading config file '%s' ...", $path;
        my $j = 0;
        $section_read_order{GLOBAL} = [$i, $j++];
        my @file_sections = ("GLOBAL");
        my $hoh = $reader->read_file(
            $path,
            sub {
                my %args = @_;
                return unless $args{event} eq 'section';
                my $section = $args{section};
                push @file_sections, $section
                    unless grep {$section eq $_} @file_sections;
                $section_read_order{$section} = [$i, $j++];
            },
        );
        push @read, $path;
      SECTION:
        for my $section (@file_sections) {
            my $hash = $hoh->{$section};

            my $s = $section; $s =~ s/\s*\S*=.*\z//; # strip key=value pairs
            $s = 'GLOBAL' if $s eq '';

            if ($args{hook_section}) {
                my $res = $args{hook_section}->($section, $hash);
                if ($res->[0] == 204) {
                    log_trace "[pericmd] Skipped config section '$section' ".
                        "in file '$path': hook_section returns 204";
                    next SECTION;
                } elsif ($res->[0] >= 400 && $res->[0] <= 599) {
                    return [$res->[0], "Error when reading config file '$path'".
                                ": $res->[1]"];
                }
            }

            next unless !defined($wanted_section) || $s eq $wanted_section;

            for (keys %$hash) {
                $res{$section}{$_} = $hash->{$_};
            }
        }
    }
    [200, "OK", \%res, {
        'func.read_files' => \@read,
        'func.section_read_order' => \%section_read_order,
    }];
}

$SPEC{get_args_from_config} = {
    v => 1.1,
    args => {
        r => {},
        config => {},
        args => {},
        subcommand_name => {},
        config_profile => {},
        common_opts => {},
        meta => {},
        meta_is_normalized => {},
    },
};
sub get_args_from_config {
    my %fargs = @_;

    my $r       = $fargs{r};
    my $conf    = $fargs{config};
    my $progn   = $fargs{program_name};
    my $scn     = $fargs{subcommand_name} // '';
    my $profile = $fargs{config_profile};
    my $args    = $fargs{args} // {};
    my $copts   = $fargs{common_opts};
    my $meta    = $fargs{meta};
    my $found;

    unless ($fargs{meta_is_normalized}) {
        require Perinci::Sub::Normalize;
        $meta = Perinci::Sub::Normalize::normalize_function_metadata($meta);
    }

    my $csro = $r->{_config_section_read_order} // {};
    my @sections = sort {
        # sort according to the order the section is seen in the file
        my $csro_a = $csro->{$a} // [0,0];
        my $csro_b = $csro->{$b} // [0,0];
        $csro_a->[0] <=> $csro_b->[0] ||
            $csro_a->[1] <=> $csro_b->[1] ||
            $a cmp $b
        } keys %$conf;

    my %seen_profiles; # for debugging message
    for my $section0 (@sections) {
        my %keyvals;
        my $sect_name;
        for my $word (split /\s+/, $section0) {
            if ($word =~ /(.*?)=(.*)/) {
                $keyvals{$1} = $2;
            } else {
                $sect_name //= $word;
            }
        }
        $seen_profiles{$keyvals{profile}}++ if defined $keyvals{profile};

        my $sect_scn     = $keyvals{subcommand} // '';
        my $sect_profile = $keyvals{profile};

        # if there is a subcommand name, use section with no subcommand=... or
        # the matching subcommand
        if (length $scn) {
            if (length($sect_scn) && $sect_scn ne $scn) {
                log_trace(
                    "[pericmd] Skipped config section '%s' (%s)",
                    $section0, "subcommand does not match '$scn'",
                );
                next;
            }
        } else {
            if (length $sect_scn) {
                log_trace(
                    "[pericmd] Skipped config section '%s' (%s)",
                    $section0, "only for a certain subcommand",
                );
                next;
            }
        }

        # if user chooses a profile, only use section with no profile=... or the
        # matching profile
        if (defined $profile) {
            if (defined($sect_profile) && $sect_profile ne $profile) {
                log_trace(
                    "[pericmd] Skipped config section '%s' (%s)",
                    $section0, "profile does not match '$profile'",
                );
                next;
            }
            $found = 1 if defined($sect_profile) && $sect_profile eq $profile;
        } else {
            if (defined($sect_profile)) {
                log_trace(
                    "[pericmd] Skipped config section '%s' (%s)",
                    $section0, "only for a certain profile",
                );
                next;
            }
        }

        # only use section marked with program=... if the program name matches
        if (defined($progn) && defined($keyvals{program})) {
            if ($progn ne $keyvals{program}) {
                log_trace(
                    "[pericmd] Skipped config section '%s' (%s)",
                    $section0, "program does not match '$progn'",
                );
                next;
            }
        }

        # if user specifies env=... then apply filtering by ENV variable
        if (defined(my $env = $keyvals{env})) {
            my ($var, $val);
            if (($var, $val) = $env =~ /\A(\w+)=(.*)\z/) {
                if (($ENV{$var} // '') ne $val) {
                    log_trace(
                        "[pericmd] Skipped config section '%s' (%s)",
                        $section0, "env $var has non-matching value '".
                            ($ENV{$var} // '')."'",
                    );
                    next;
                }
            } elsif (($var, $val) = $env =~ /\A(\w+)!=(.*)\z/) {
                if (($ENV{$var} // '') eq $val) {
                    log_trace(
                        "[pericmd] Skipped config section '%s' (%s)",
                        $section0, "env $var has that value",
                    );
                    next;
                }
            } elsif (($var, $val) = $env =~ /\A(\w+)\*=(.*)\z/) {
                if (index(($ENV{$var} // ''), $val) < 0) {
                    log_trace(
                        "[pericmd] Skipped config section '%s' (%s)",
                        $section0, "env $var has value '".
                            ($ENV{$var} // '')."' which does not contain the ".
                                "requested string"
                    );
                    next;
                }
            } else {
                if (!$ENV{$env}) {
                    log_trace(
                        "[pericmd] Skipped config section '%s' (%s)",
                        $section0, "env $env is not set/true",
                    );
                    next;
                }
            }
        }

        log_trace("[pericmd] Reading config section '%s'", $section0);

        my $as = $meta->{args} // {};
        for my $k (keys %{ $conf->{$section0} }) {
            my $v = $conf->{$section0}{$k};
            if ($copts->{$k} && $copts->{$k}{is_settable_via_config}) {
                my $sch = $copts->{$k}{schema};
                if ($sch) {
                    require Data::Sah::Normalize;
                    $sch = Data::Sah::Normalize::normalize_schema($sch);
                    # since IOD might return a scalar or an array (depending on
                    # whether there is a single param=val or multiple param=
                    # lines), we need to arrayify the value if the argument is
                    # expected to be an array.
                    if (ref($v) ne 'ARRAY' && $sch->[0] eq 'array') {
                        $v = [$v];
                    }
                }
                $copts->{$k}{handler}->(undef, $v, $r);
            } else {
                # when common option clashes with function argument name, user
                # can use NAME.arg to refer to function argument.
                $k =~ s/\.arg\z//;

                # since IOD might return a scalar or an array (depending on
                # whether there is a single param=val or multiple param= lines),
                # we need to arrayify the value if the argument is expected to
                # be an array.
                if (ref($v) ne 'ARRAY' && $as->{$k} && $as->{$k}{schema} &&
                        $as->{$k}{schema}[0] eq 'array') {
                    $v = [$v];
                }
                $args->{$k} = $v;
            }
        }
    }
    log_trace("[pericmd] Seen config profiles: %s",
              [sort keys %seen_profiles]);

    [200, "OK", $args, {'func.found'=>$found}];
}

1;
# ABSTRACT: Utility routines related to config files
