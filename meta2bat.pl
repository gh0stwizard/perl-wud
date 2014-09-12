#!perl

# meta2bat.pl -- Generate bat file from meta
#
# This program is part of Perl Windows Updates Downloader
#
# This is free software; you can redistribute it and/or modify it
# under the same terms as the Perl 5 programming language system itself.


use strict;
use warnings;
use vars qw/$PROGRAM_NAME $VERSION/;
use Cwd ();
use POSIX ();
use File::Spec::Functions ();
use Getopt::Long qw/:config no_ignore_case bundling/;
use File::Find ();
use Carp qw/croak/;
use Encode ();


$PROGRAM_NAME = "meta2bat.pl"; $VERSION  = '0.02';

my $retval = GetOptions
( 
  \my %options,
  'help|h', 'version', 'dir|D=s', 'output|O=s',
  'os-type|t=s', 'arch|a=s', 'exclude|E=s',
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

&process( @options{qw(dir output os-type arch exclude)} );
exit 0;


#----------------------------------------------------------------------


# parse_file() returns an array reference
sub TITLE 	{ 0 }
sub FILENAME 	{ 1 }
sub DATE 	{ 2 }
sub ADDRESS 	{ 3 }


sub process($$$$$) {
  my ($workdir, $output, $ostype, $osarch, $exclude) = @_;
  
  if (defined $workdir) {
    $workdir = &Cwd::abs_path($workdir);
  } else {
    $workdir = &Cwd::abs_path(&Cwd::cwd());
  }
  
  $ostype = 'winxp' if not defined $ostype;
  $osarch = 'x86' if not defined $osarch;
  $exclude = '' if not defined $exclude;
  
  my %data;

  &File::Find::find({ 'wanted' => sub {
    return if (not m/\.meta$/);
    return if $File::Find::name eq $File::Find::dir;
  
    my $info = &parse_file( $File::Find::name );
    
    my $filename = $info->[&FILENAME()];
    $filename =~ /(x86|ia64|x64)/i;
    my $arch = lc "$1";
    
    return if $arch ne $osarch;
    
    for my $ex (split /\,/, $exclude) {
      $filename =~ m/\Q$ex\E/i and return;
    }
    
    my ($mday, $mon, $year) = split /\./, $info->[&DATE()];
    my $time = &POSIX::mktime(0, 0, 0, $mday, $mon - 1, $year - 1900);
    
    $data{$filename} = [ $time, $info->[&TITLE()], $info->[&ADDRESS()] ];
  }}, $workdir);
  
  my @files = sort { $data{$a}->[0] <=> $data{$b}->[0] } keys %data;
  my $total = @files;
  my $fh;
  
  if (defined $output) {  
    open $fh, ">:encoding(UTF-8)", $output
      or croak sprintf("open %s: %s", $output, $!);
  } else {
    open $fh, ">&STDOUT"
      or croak "dup STDOUT: $!";
  }
  
  local $\ = "\r\n";
  
  print $fh '@echo off';
  print $fh 'setlocal';
  print $fh 'SET PATHTOFIXES=C:\Updates';
  print $fh '';
  
  if ($ostype eq 'winxp') {
    for (my $i = 0; $i < $total; $i++) {
      my $filename = $files[$i];
      my $title = $data{$filename}->[1];
      my $url = $data{$filename}->[2];
      
      printf $fh "REM %s\r\n", &Encode::decode_utf8($title); # add title
      printf $fh "REM %s\r\n", $url; # add url
      printf $fh "START /W %%PATHTOFIXES%%\\%s /q /u /n /z\r\n", $filename;
      print $fh '';
    }
  } elsif ($ostype eq 'win7') {
    for (my $i = 0; $i < $total; $i++) {
      my $filename = $files[$i];
      my $title = $data{$filename}->[1];
      my $url = $data{$filename}->[2];
      
      printf $fh "REM %s\r\n", &Encode::decode_utf8($title); # add title
      printf $fh "REM %s\r\n", $url; # add url
      printf $fh "START /W %%PATHTOFIXES%%\\%s /q /u /n /z\r\n", $filename;
      print $fh '';
    }
  } else {
    local $\ = "\n";
    print STDERR "Invalid value for options --os-type";
    close $fh;
    exit 1;
  }
  
  print $fh 'SET Choice=';
  print $fh 'SET /P Choice=Press any key to continue ...';
  print $fh 'GOTO End';
  print $fh ':End';
  
  close $fh or croak sprintf("close %s: %s", $output, $!);
}

sub parse_file($) {
  my ($file) = @_;
  
  my $filename = '';
  my $title = '';
  my $date = '';
  my $url = '';
  
  open FILE, "<", $file
    or croak sprintf("open %s: %s", $file, $!);
    
  while (<FILE>) {
    s/\r?\n$//;
    m/^Title: (.*)/ and $title = "$1", next;
    m/^URL: (.*)/ and $url = "$1", next;
    m/^File: (.*)/ and $filename = "$1", next;
    m/^Date: (.*)/ and $date = "$1";
  }
    
  close FILE
    or croak sprintf("close %s: %s", $file, $!);
    
  return [$title, $filename, $date, $url];
}

sub print_help() {
    printf "Allowed options:\n";

    my $h = "  %-24s %-52s\n";

    printf $h, "-h [--help]", "show this usage information";
    printf $h, "--version", "show version information";

    # main options
    printf $h, "-D [--dir]", "the directory where *.meta files placed";
    printf $h, "", "- default is current directory";
    
    printf $h, "-O [--output]", "path to bat file";
    printf $h, "", "- default is apply-updates.bat";
    
    printf $h, "-t [--os-type]", "OS type";
    printf $h, "", "- supported types: winxp (default), win7";
    
    printf $h, "-a [--arch]", "archetecture";
    printf $h, "", "- supported architectures: x86 (default), x64";
    
    printf $h, "-E [--exclude]", "comma-separated list to exclude";
    printf $h, "- for an example, exclude IE7, IE8 updates: -E IE7,IE8";
}