#!perl

# Perl Windows Updates Downloader
#
# This is free software; you can redistribute it and/or modify it
# under the same terms as the Perl 5 programming language system itself.

use strict;
use warnings;
use vars qw/$PROGRAM_NAME $VERSION/;
use POSIX ();
use Cwd ();
use File::Spec::Functions ();
use Getopt::Long qw/:config no_ignore_case bundling/;

$PROGRAM_NAME = "pwud.pl"; $VERSION  = '0.03';

my $retval = GetOptions
( 
  \my %options,
  'help|h', 'version', 'debug|d', 'verbose|v',
  'pidfile|P=s', 'home|H=s', 'fork', 'quiet',
  'logfile|L=s', 'enable-syslog', 'syslog-facility=s',
  'file|F=s', 'dst-dir|D=s', 'dns-servers|N=s',
);

if (defined $retval and !$retval) {
    # unknown option workaround
    print "use --help for help\n";
    exit 1;
}

if (exists $options{'help'}) {
    &print_help();
    exit 0;
}

if (exists $options{'version'}) {
    printf "%s version %s\n", $PROGRAM_NAME, $VERSION;
    exit 0;
}


# use only absolute paths
&fix_paths();
# check/get pidfile filename
$ENV{'PIDFILE'} = &get_pidfile();
# program variables
eval q{
  my %map = (
    'file' 		=> 'FILE',
    'dst-dir'		=> 'DL_PATH',
    'dns-servers'	=> 'DNS_SERVERS',
  );

  for my $name (keys %map) {
    next if not defined $options{ $name };
    $ENV{$map{$name}} = $options{ $name };
  }
};
# Set up AnyEvent::Log environment variable.
$ENV{'PERL_ANYEVENT_LOG'} = &ae_log_string();
# for staticperl
&patch_programname();
# daemonize when needed
&daemonize() if (exists $options{'fork'});
# Start the main program after fork.
unless ( my $rv = do $PROGRAM_NAME ) {
    warn "Couldn't parse $PROGRAM_NAME: $@" if $@;
    warn "Couldn't do $PROGRAM_NAME: $!"    unless defined $rv;
    warn "Couldn't run $PROGRAM_NAME"       unless $rv;
}

exit 0;


#=---------------------------------------------------------------------


# fix relative paths to absolute as needed
sub fix_paths() {
    return if $^O eq 'MSWin32'; # TODO

    my $pwd = &Cwd::abs_path( &Cwd::cwd() );

    for my $opt (qw(logfile home pidfile file dst-dir)) {
        next if (!exists $options{$opt});
        next if ($options{$opt} =~ m/^\//);
        my $path = &File::Spec::Functions::catfile($pwd, $options{$opt});
        $options{$opt} = &Cwd::abs_path($path);
    }
}

# print usage
sub print_help() {
    printf "Allowed options:\n";

    my $h = "  %-32s %-45s\n";

    printf $h, "-h [--help]", "show this usage information";
    printf $h, "--version", "show version information";
    printf $h, "-d [--debug]", "be verbose";
    printf $h, "-v [--verbose]", "be much more verbose";

    # main options
    printf $h, "-F [--file]", "file with urls to be downloaded";
    printf $h, "", "- REQUIRED";
    printf $h, "-D [--dst-dir]", "the directory where files will be stored";
    printf $h, "", "- default is \$TMP_DIR";
    printf $h, "-N [--dns-servers]", "comma separated list of dns servers";
    printf $h, "", "- default is 127.0.0.1";

    # additional options
    printf $h, "--fork", "run process in background";

    printf $h, "-H [--home] arg", "working dir when fork";
    printf $h, "", "- default is /";

    printf $h, "--quiet", "disable logging";

    printf $h, "-P [--pidfile] arg", "full path to pidfile";
    printf $h, "-L [--logfile] arg", "full path to logfile";
    printf $h, "", "- if not set, log to stdout";

    printf $h, "--enable-syslog", "log via syslog";
    printf $h, "", "- disables logging to file";
    printf $h, "--syslog-facility", "syslog facility";
    printf $h, "", "- default is local7";
}

# Workaround to
#   running the program via staticperl vs common perl.
#
# Explaination:
# Common perl after fork() called will be chrooted to real '/'.
# This is usual case.
#
# Meantime, there are very high possibility that user is just testing 
# this program and user did NOT set up the environment variable 
# PERL5LIB with correct value.
#
# So, we put real path to MyService/ directory into @INC.
# After that all modules in MyService/ will be successfuly loaded :-)
sub patch_programname() {
    return if $0 eq '-e'; # staticperl uses '-e' as $0
    return if $^O eq 'MSWin32'; # TODO

    if (my $filepath = $0 =~ /(.*)\/.*?$/m) {
        $filepath = "$1";
        unshift @INC, $filepath;
        # use fullpath for do(...), see above
        $PROGRAM_NAME = 
          &File::Spec::Functions::catfile( $filepath, $PROGRAM_NAME );
    } else {
      $PROGRAM_NAME = &File::Spec::Functions::catfile
      (
        &Cwd::abs_path(&Cwd::cwd()),
        $PROGRAM_NAME
      );
    }
}

# pidfile lock
sub get_pidfile() {
    return if  not exists $options{'pidfile'};

    my $pid_file = $options{'pidfile'} || time() . '.pid';
    die "pidfile \`$pid_file\' already exits" if -e $pid_file;

    return $pid_file;
}

# perldoc AnyEvent::Log
sub ae_log_string() {
    # We'll control behaviour of AnyEvent::Log via environment variables
    my $AE_LOG = (exists $options{'verbose'})
        ? 'filter=trace'
        : (exists $options{'debug'})
            ? 'filter=debug'
            : 'filter=note'; # default log level

    if (exists $options{'logfile'}) {
        # enable syslog + logfile
        if (exists $options{'enable-syslog'}) {
            $AE_LOG .= sprintf ":log=file=%s=+%syslog:%syslog=%s",
                $options{'logfile'},
                (exists $options{'syslog-facility'}) 
                    ? $options{'syslog-facility'}
                    : 'LOG_DAEMON';
        } else {
            $AE_LOG .= sprintf ":log=file=%s", $options{'logfile'};
        }
    } elsif (exists $options{'enable-syslog'}) {
        # syslog
        $AE_LOG .= sprintf ":log=syslog=%s",
            $options{'syslog-facility'}
                ? $options{'syslog-facility'}
                : 'LOG_DAEMON';
    } elsif (exists $options{'quiet'}) {
        # disable logging totally
        $AE_LOG .= ':log=nolog';
    } else {
        # print to stdout
        $AE_LOG .= ':log=';
    }

    return $AE_LOG;
}

sub daemonize() {
    return if $^O eq 'MSWin32'; # TODO

    # chroot
    my $rootdir = $options{'home'} ? $options{'home'} : '/';
    chdir ($rootdir)                || die "chdir \`$rootdir\': $!";
    
    # Due to bug/feature of perl we do not close standard handlers.
    # Otherwise, Perl will complain and throw warning messages 
    # about reopenning 0, 1 and 2 filehandles.
    open ( STDIN, "< /dev/null" )   || die "Can't read /dev/null: $!";
    open ( STDOUT, "> /dev/null" )  || die "Can't write /dev/null: $!";
    defined (my $pid = fork())      || die "Can't fork: $!";
    exit if $pid;
    ( &POSIX::setsid() != -1 )      || die "Can't start a new session: $!";
    open ( STDERR, ">&STDOUT" )     || die "Can't dup stdout: $!";
}
