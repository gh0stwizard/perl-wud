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


$PROGRAM_NAME = "meta2bat.pl"; $VERSION  = '0.03';

my $retval = GetOptions
( 
  \my %options,
  'help|h', 'version', 'dir|D=s', 'output|O=s',
  'arch|a=s', 'exclude|E=s',
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

&process( @options{qw(dir output arch exclude)} );
exit 0;


#----------------------------------------------------------------------


# parse_file() returns an array reference
sub TITLE 	{ 0 }
sub FILENAME 	{ 1 }
sub DATE 	{ 2 }
sub ADDRESS 	{ 3 }


sub process($$$$) {
  my ($workdir, $output, $osarch, $exclude) = @_;
  
  if (defined $workdir) {
    $workdir = &Cwd::abs_path($workdir);
  } else {
    $workdir = &Cwd::abs_path(&Cwd::cwd());
  }
  
  $osarch = 'x86' if not defined $osarch;
  $exclude = '' if not defined $exclude;
    
  my $fh;
    
  if (defined $output) {
    open($fh, ">:encoding(UTF-8)", $output)
      or croak sprintf("open %s: %s", $output, $!);
  } else {
    open($fh, ">&STDOUT") or croak "dup STDOUT: $!";
    binmode($fh, ":utf8");
  }
  
  my $data = &collect_data($workdir, $osarch, $exclude);
  my @files = sort { $data->{$a}[0] <=> $data->{$b}[0] } keys %$data;
  my $total = @files;
    
  if ($total == 0) {
    print STDERR "No meta files found\n";
    exit 1;
  }
    
  &print_header($fh);
    
  for (my $i = 0; $i < $total; $i++) {
    &print_command($fh, $files[$i], $data);
  }
    
  local $\ = "\r\n";
  
  print $fh 'REM Cleaning up...';
  print $fh 'call :remove_tmp_dirs';
  print $fh '';
  print $fh 'REM :start';
  print $fh 'exit /b';
  
  close($fh) or croak sprintf("close %s: %s", $output, $!);
}

sub collect_data($$$) {
  my ($workdir, $osarch, $exclude) = @_;

  my %data;

  &File::Find::find({ 'wanted' => sub {
    return if (not m/\.meta$/);
    return if ($File::Find::name eq $File::Find::dir);
  
    my $info = &parse_file( $File::Find::name );
    my $arch = '';
    
    (my $filename = $info->[&FILENAME()]) =~ /(x86|ia64|x64)/i;
    
    if (defined $1) {
      $arch = lc "$1";
    } else {
      if ($filename =~ /\.dmg$/) {
        $arch = 'macos';
      } elsif ($filename =~ /\.exe$/) {
        $arch = 'x86';
      } else {
        printf STDERR "??? arch: %s\n %s\n",
          $filename, $File::Find::name;
      }
    }
    
    for my $key (split /\,/, $exclude) {
      $filename =~ m/\Q$key\E/i and return;
    }
    
    my $date = $info->[ &DATE() ];
    my ($mday, $mon, $year) = (31, 12, 1999);
    
    if ($date =~ m/\d{1,2}\.\d{1,2}\.\d{4}/) {
      ($mday, $mon, $year) = split /\./, $date;
    } elsif ($date =~ m/\d{1,2}\/\d{1,2}\/\d{4}/) {
      ($mday, $mon, $year) = split /\//, $date;
    } else {
      printf STDERR "??? date: %s\n %s\n",
        $date, $File::Find::name;
    }
    
    if ($arch eq $osarch) {
      $data{$filename} = [
        &POSIX::mktime(0, 0, 0, $mday, $mon - 1, $year - 1900),
        $info->[ &TITLE() ],
        $info->[ &ADDRESS() ],
      ];
    }
  }}, $workdir);

  return \%data;
}

sub print_command($$\%) {
  my ($fh, $filename, $data) = @_;
  
  my ($time, $title, $url) = @{ $data->{$filename} };
      
  $title = &Encode::decode_utf8($title);
      
  printf $fh "REM %s\r\n", $title;
  printf $fh "REM %s\r\n", &POSIX::strftime("%d.%m.%Y", localtime($time));
  printf $fh "REM %s\r\n", $url;
  printf $fh "echo %s ...\r\n", $filename;
      
  if ($filename =~ m/\-KB\d+\-/) {
    printf $fh "START /W %%PATHTOFIXES%%\\%s /q /u /n /z\r\n\r\n",
      $filename;
    return 1;
  }
  
  if ($title =~ m/DirectX/) {
    printf $fh "call :create_tmp_dir\r\n";
    printf $fh "START /W %%PATHTOFIXES%%\\%s /Q /T:%%TEMPDIR%%\r\n",
      $filename;
    printf STDERR "*** %s: using '/Q /T' (DirectX-file)\n",
      $filename;
  } else {
    printf $fh "START /W %%PATHTOFIXES%%\\%s /Q\r\n",
      $filename;
    printf STDERR "*** %s: using '/Q' key (non-Update.exe file)\n",
      $filename;
  }
  
  print $fh '';
}

sub print_header($) {
  my ($fh) = @_;
  
  (my $quote = <<'EOF') =~ s/\n/\r\n/gm;
@echo off
setlocal
SET PATHTOFIXES=C:\Updates
SET TEMPDIR_BASEPATH=C:\Temp
SET TEMPDIR=C:\Temp\meta2bat
SET /A TEMPINC=0

call :start
@pause
exit 0

:create_tmp_dir
REM Create a temporary directory
REM Set %TEMPDIR% to current temporary directory
set TEMPDIR=%TEMPDIR_BASEPATH%\%date:~-10%-%TEMPINC%
set /a TEMPINC=%TEMPINC%+1

IF NOT EXIST %TEMPDIR% (
    MD %TEMPDIR%
    exit /b
)

REM When failed exit immediatly
echo %TEMPDIR% already exists!
@pause
exit 1

:remove_tmp_dirs
REM Cleanup self-created temporary directories
@echo on
for /l %%i in (0,1,%TEMPINC%) do RD /S /Q %TEMPDIR_BASEPATH%\%date:~-10%-%%i
@echo off
exit /b

:start
EOF

  local $\ = "\r\n";
  
  printf $fh "REM auto-generated by meta2bat.pl at %s\r\n\r\n",
    &POSIX::strftime("%d.%m.%Y %H:%M:%S", localtime);
  print $fh $quote;
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
    
    printf $h, "-O [--output]", "path to batch file";
    printf $h, "", "- default is stdout";
    
    printf $h, "-a [--arch]", "architecture";
    printf $h, "", "- supported architectures: x86 (default), x64";
    
    printf $h, "-E [--exclude]", "comma-separated list to exclude";
    printf $h, "", "- for an example, exclude IE7, IE8 updates: -E IE7,IE8";
}
