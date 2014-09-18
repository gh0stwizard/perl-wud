#!perl

# Perl Windows Updates Downloader
#
# This is free software; you can redistribute it and/or modify it
# under the same terms as the Perl 5 programming language system itself.


package main;

use strict;
use warnings;
use common::sense;
use EV 4.0;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::HTTP;
use Time::HiRes qw/gettimeofday tv_interval/;
use Carp ();
use File::Spec::Functions ();


# Global variables
my $PIDFILE = $ENV{'PIDFILE'};
my $INPUT_FILE = $ENV{'FILE'};
my $DL_PATH = $ENV{'DL_PATH'};
my $DNS = $ENV{'DNS_SERVERS'};
my $DRY_RUN = $ENV{'DRY_RUN'};
# AnyEvent::HTTP settings
my $HTTP_MAX_RECURSE = $ENV{'HTTP_MAX_RECURSE'} 	|| 10;
my $HTTP_MAX_PER_HOST = $ENV{'HTTP_MAX_PER_HOST'} 	|| 4;

my @URL_LIST;
my %PROGRESS;

{
  $EV::DIED = sub { AE::log fatal => "$@" };
  my $t; $t = AE::timer 0, 0, sub { undef $t; &startup() };
}


#=---------------------------------------------------------------------


sub startup() {
  if (&prepare_check()) {
    &download_all();
  } else {  
    AE::log fatal => "failed to start due errors above";
  }
}

sub prepare_check() {
  &check_dl_dir() 	|| return;
  &check_filelist()	|| return;
  return 1;
}

sub check_dl_dir() {
  return 1;
}

sub check_filelist() {
  return 1;
}


#=---------------------------------------------------------------------


sub download_all() {
  &import_urls();
  &setup_dns();


  # tune AnyEvent::HTTP  
  $AnyEvent::HTTP::MAX_RECURSE = $HTTP_MAX_RECURSE;
  $AnyEvent::HTTP::MAX_PER_HOST = $HTTP_MAX_PER_HOST;
  
  
  for (my $i = 0; $i < @URL_LIST; $i++) {
    my $url = $URL_LIST[$i];
    my %data = ( url_original => $url );
    $PROGRESS{$url} = 0;
    
    http_get $url, sub { &process_response(@_, \%data) };
  }
  
  my $w_progress; $w_progress = AE::timer 1, 1, sub {
    for my $state (values %PROGRESS) {
      return if $state == 0;
    }
   
    # finished all jobs, exiting
    # anyevent::dns keeps loop running forever :\
    undef $w_progress;
    EV::unloop;
  };
}

sub setup_dns() {
  my @dns;
  
  for my $ip (split /\s*\,\s*/, $DNS) {
    push @dns, &AnyEvent::Socket::parse_address($ip);
  }
  
  if (@dns == 0) {
    push @dns, &AnyEvent::Socket::parse_address('127.0.0.1');
  }

  $AnyEvent::DNS::RESOLVER = new AnyEvent::DNS
    # FIXME
    # bug in ae:dns with multiple nameservers causes false-positive errors
    server          => \@dns,
    timeout         => [1, 3, 5],
    max_outstanding => 500,
    reuse           => 1,
    untaint         => 0,
  ;
  
  return;
}

sub process_response {
  my ($body, $hdr, $data) = @_;
  
  my $status = $hdr->{'Status'};
  my $url_cur = $hdr->{'URL'};
  my $url_ori = $data->{'url_original'};
  
  $PROGRESS{$url_ori} = 1;
    
  if ($status != 200) {
    AE::log error => "Failed to load page:\n %s\n %s",
      $url_cur, $url_ori;
    AE::log error => " Status: %d Reason: %s",
      $status, $hdr->{'Reason'};
    return;
  }
  
  if ($hdr->{'content-disposition'} eq 'attachment') {
    AE::log error => "Invalid content type:\n %s\n %s",
      $url_cur, $url_ori;
    return;
  }
  
  my $pwud = new PWUD::Main
    body 		=> \$body,
    url_original 	=> $url_ori,
    url_current 	=> $url_cur,
  ;
  
  $data->{'title'} = $pwud->get_title() or return;  
  $data->{'url_dl'} = $pwud->get_link_download() or return;
  $data->{'url_nfo'} = $pwud->get_link_details() or return;
  $data->{'url_req'} = $pwud->get_link_require() or return;
  
  $PROGRESS{$url_ori} = 0;
  
  # file inforamtion page
  http_get $data->{'url_nfo'}, sub {
    my ($body, $hdr) = @_;
    
    my $status = $hdr->{'Status'};
    my $url_cur = $hdr->{'URL'};
    my $url_ori = $data->{'url_original'};
  
    $PROGRESS{$url_ori} = 1;
    
    if ($status != 200) {
      AE::log error => "Failed to load page:\n %s\n %s",
        $url_cur, $url_ori;
      AE::log error => " Status: %d Reason: %s",
        $status, $hdr->{'Reason'};
      return;
    }
    
    my $pwud = new PWUD::Details
      body 		=> \$body,
      url_original 	=> $url_ori,
      url_current 	=> $url_cur,
    ;

    $data->{'file_version'} = $pwud->get_version() or return;
    $data->{'date_publish'} = $pwud->get_publish() or return;
    my ($files, $sizes) = $pwud->get_files() or return;
    $data->{'file_name'} = $files;
    $data->{'file_size'} = $sizes;
    
    if (my $kb_sb = $pwud->get_bulletins()) {
      $data->{'kb-sb'} = $kb_sb;
    } else {
      AE::log warn => "Failed to find security bulletin:\n %s\n %s",
        $hdr->{'URL'}, $data->{'url_original'};    
    }
    
    $PROGRESS{$url_ori} = 0;
        
    # requirements page
    http_get $data->{'url_req'}, sub {
      my ($body, $hdr) = @_;
      
      my $status = $hdr->{'Status'};
      my $url_cur = $hdr->{'URL'};
      my $url_ori = $data->{'url_original'};
  
      $PROGRESS{$url_ori} = 1;

      if ($status != 200) {
        AE::log error => "Failed to load page:\n %s\n %s",
          $url_cur, $url_ori;
        AE::log error => " Status: %d Reason: %s",
          $status, $hdr->{'Reason'};
        return;
      }
    
      my $pwud = new PWUD::Require
        body 		=> \$body,
        url_original 	=> $url_ori,
        url_current 	=> $url_cur,
      ;
      
      if (my $req = $pwud->get_requirements()) {
        $data->{'required'} = $req;
      } else {
        AE::log warn => "Failed to find requirements:\n %s\n %s",
          $hdr->{'URL'}, $data->{'url_original'};      
      }
      
      $PROGRESS{$url_ori} = 0;
      
      # download page, extract urls
      http_get $data->{'url_dl'}, sub {
        my ($body, $hdr) = @_;
        
        my $status = $hdr->{'Status'};
        my $url_cur = $hdr->{'URL'};
        my $url_ori = $data->{'url_original'};
  
        $PROGRESS{$url_ori} = 1;

        if ($status != 200) {
          AE::log error => "Failed to load page:\n %s\n %s",
            $url_cur, $url_ori;
          AE::log error => " Status: %d Reason: %s",
            $status, $hdr->{'Reason'};
          return;
        }
        
        my $pwud = new PWUD::Download
          body 		=> \$body,
          url_original 	=> $url_ori,
          url_current 	=> $url_cur,
        ;
    
        $data->{'download'} = $pwud->get_links() or return;
        
        if (not $DRY_RUN) {
          &store_data($data);
        }
        
        return;
      }; # download
    }; # requirements
  };
}


sub store_data($) {
  my $data = shift;
  
  my $total_files = @{ $data->{'file_name'} };
  
  for (my $i = 0; $i < $total_files; $i++) {
    my $file = &File::Spec::Functions::catfile
    (
      $DL_PATH,
      join('.', $data->{'file_name'}[$i], 'meta'),
    );
  
    open FILE, ">", $file
      or &AE::log(error => "open %s: %s", $file, $!), return;

    printf FILE "Title: %s\n", $data->{'title'};
    printf FILE "URL: %s\n", $data->{'url_original'};
    printf FILE "File: %s\n", $data->{'file_name'}[$i];
    printf FILE "Size: %s\n", $data->{'file_size'}[$i];
    printf FILE "Version: %s\n", $data->{'file_version'};
    printf FILE "Date: %s\n", $data->{'date_publish'};
    printf FILE "Download: %s\n", $data->{'download'}[$i];
    
    if (exists $data->{'required'}) {
      $data->{'required'} =~ s/^\s+//;
      $data->{'required'} =~ s/\s+$//;
      printf FILE "Requirements: %s\n", $data->{'required'};
    }
  
    if (exists $data->{'kb-sb'}) {
      printf FILE "References:\n";
      for my $info (@{ $data->{'kb-sb'} }) {
        next if (@$info != 2);
        printf FILE " %s\n", $info->[1];
      }
    }
  
    close FILE
      or &AE::log(error => "close %s: %s", $file, $!), return;    
  }
  
  return 1;
}

sub import_urls() {
  AE::log debug => "Importing from \`%s\'", $INPUT_FILE;

  open FILE, "<", $INPUT_FILE
    or AE::log fatal => "open %s: %s", $INPUT_FILE, $!;
    
  while (<FILE>) {
    s/\r?\n$//;
    push @URL_LIST, $_;
  }
  
  AE::log debug => "Imported: %d", $.;
  
  close FILE
    or AE::log fatal => "close %s: %s", $INPUT_FILE, $!;
}


#
# Run loop
#
EV::run; scalar "Dream in my fantasy";


package PWUD;

use strict;
use warnings;
use HTML::TreeBuilder 5 -weak;
use AE ();


BEGIN {
  use Exporter ();
    
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
  
  $VERSION     = '1.000';
  @ISA         = qw( Exporter );
  @EXPORT      = ( );
  %EXPORT_TAGS = 
  (
    main => [ qw
      (
        E_NOERROR
        E_CONTENT
        E_TITLE
        E_DOWNLOAD
        E_DETAILS
        E_REQUIRE
      )
    ],
    details => [ qw
      (
        E_NOERROR
        E_FILEINFO
        E_VERSION
        E_PUBLISH
        E_FILES
      )
    ],
    require => [ qw
      (
        E_NOERROR
      )
    ],
    download => [ qw
      (
        E_NOERROR
        E_TABLE
      )
    ],
  );
  
  &Exporter::export_ok_tags('main');
  &Exporter::export_ok_tags('details');
  &Exporter::export_ok_tags('require');
  &Exporter::export_ok_tags('download');
}

sub new {
  my ($class, %args) = @_;
  
  my $body = delete $args{'body'};
  my $self = bless \%args, $class;
  
  $self->{'_root'} = HTML::TreeBuilder->new_from_content($body);
  
  return $self;
}

sub E_NOERROR 	{  0 }
# mainpage
sub E_CONTENT 	{  1 }
sub E_TITLE 	{  2 }
sub E_DOWNLOAD	{  3 }
sub E_DETAILS	{  4 }
sub E_REQUIRE	{  5 }
# details
sub E_FILEINFO	{  6 }
sub E_VERSION	{  7 }
sub E_PUBLISH	{  8 }
sub E_FILES	{  9 }
# require
# ...
# download
sub E_TABLE	{ 10 }

{
  my @errors = 
  (
    "There is no error:\n %s\n %s",
    "Unable to parse content:\n %s\n %s",
    "Failed to find title:\n %s\n %s",
    "Failed to find download link:\n %s\n %s",
    "Failed to find details link:\n %s\n %s",
    "Failed to find supported os:\n %s\n %s",
    "Failed to find file info:\n %s\n %s",
    "Failed to find version:\n %s\n %s",
    "Failed to find publish date:\n %s\n %s",
    "Failed to find filenames or filesizes:\n %s\n %s",
    "Failed to find download table:\n %s\n %s",
  );

  sub error {
    my ($self, $code) = @_;
    
    my @urls = @$self{qw(url_current url_original)};    
    my $fstr = $errors[$code] 
      // AE::log fatal => "Internal error:\n %s\n %s", @urls;
      
    AE::log error => $fstr, @urls;
    
    return;
  }
}


package PWUD::Main;

use strict;
use warnings;
use URI ();
use AE ();

use parent -norequire, 'PWUD';
BEGIN { PWUD->import(':main') }


sub get_title {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $product_title = $root->look_down
  (
    _tag	=> "div",
    class	=> "product-title",
  );
  
  $product_title or return $self->error( &E_CONTENT() );
  
  if (my $title = $product_title->look_down(_tag => "h1")) {
    $title = $title->as_text();
    $title =~ s/^\s+//;
    $title =~ s/\s+$//;
  
    return $title;
  }
  
  return $self->error( &E_TITLE() );
}


sub get_link_download {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $link = $root->look_down
  (
    _tag 	=> "a",
    class 	=> "mscom-link download-button dl",
  );
  
  if (defined $link) {
    my $cur = URI->new( $self->{'url_current'} );
    my $uri = URI->new_abs( $link->attr('href'), $cur );
    my $url = $uri->as_string();
    return $url;
  }
  
  return $self->error( &E_DOWNLOAD() );
}


sub get_link_details {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $link = $root->look_down
  (
    _tag	=> "a",
    'bi:cmpnm'	=> 'Details',
  );
  
  if (defined $link) {
    my $cur = URI->new( $self->{'url_current'} );
    my $uri = URI->new_abs( $link->attr('href'), $cur );
    my $url = $uri->as_string();
    return $url;
  }
  
  return $self->error( &E_DETAILS() );
}


sub get_link_require {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $link = $root->look_down
  (
    _tag	=> "a",
    'bi:cmpnm'	=> 'System Requirements',
  );
  
  if (defined $link) {
    my $cur = URI->new( $self->{'url_current'} );
    my $uri = URI->new_abs( $link->attr('href'), $cur );
    my $url = $uri->as_string();
    return $url;
  }
  
  return $self->error( &E_REQUIRE() );
}


package PWUD::Details;

use strict;
use warnings;
use URI ();
use AE ();

use parent -norequire, 'PWUD';
BEGIN { PWUD->import(':details') }


sub get_version {
  my ($self) = @_;
    
  if (not exists $self->{'_fileinfo'}) {
    $self->_fileinfo() or return;
  }
  
  my $block = $self->{'_fileinfo'};
  my $item = $block->look_down
  (
    _tag	=> "div",
    class	=> "header",
  );
  
  if (defined $item) {    
    return $item->right()->as_text();
  }
  
  return $self->error( &E_VERSION() );
}


sub get_files {
  my ($self) = @_;
    
  if (not exists $self->{'_fileinfo'}) {
    $self->_fileinfo() or return;
  }
  
  my $block = $self->{'_fileinfo'};
  my ($filename, $filesize) = $block->look_down
  (
    _tag	=> "div",
    class	=> "file-header",
  );
  
  if (defined $filename and defined $filesize) {  
    # fill filenames for all listed files
    my @names;
    my @name_nodes = $filename->right()->content_list();
    
    for (@name_nodes) {
      my $name = $_->as_text();
      $name =~ s/\\/\-/g;
      push @names, $name;
      }
    
      # fill filesize for each file
      my @sizes;
      my @size_nodes = $filesize->right()->content_list();
      push @sizes, $_->as_text() for @size_nodes;
  
      return \@names, \@sizes;
  }
  
  return $self->error( &E_FILES() );
}


sub get_publish {
  my ($self) = @_;
    
  if (not exists $self->{'_fileinfo'}) {
    $self->_fileinfo() or return;
  }
  
  my $block = $self->{'_fileinfo'};
  my $item = $block->look_down
  (
    _tag	=> "div",
    class	=> "header date-published",
  );
  
  if (defined $item) {
    return $item->right()->as_text();
  }
  
  return $self->error( &E_PUBLISH() );
}


sub get_bulletins {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $kb_sb = $root->look_down
  (
    _tag	=> "div",
    class	=> "kb-sb",
  );
    
  if (defined $kb_sb) {
    my @items = $kb_sb->content_list;
    my @list;
    
    for my $item (@items) {
      next if ($item->is_empty());
      
      if (my $url = $item->look_down(_tag => 'a')) {
        push @list, [ $item->as_text(), $url->attr('href') ];
      } else {
        push @list, [ $item->as_text() ];
      }
    }
    
    return \@list;
  }
  
  return;
}


sub _fileinfo {
  my ($self) = @_;
  
  my $root = $self->{'_root'};  
  my $block = $root->look_down
  (
    _tag	=> "div",
    class	=> "fileinfo",
  );
  
  if (defined $block) {
    $self->{'_fileinfo'} = $block;
    return $self;
  }
  
  return $self->error( &E_FILEINFO() );
}


package PWUD::Require;

use strict;
use warnings;
use URI ();
use AE ();

use parent -norequire, 'PWUD';
BEGIN { PWUD->import(':require') }


sub get_requirements {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $item = $root->look_down
  (
    _tag	=> "p",
    itemprop	=> "operatingSystem",
  );
  
  if (defined $item) {
    return $item->as_text();
  }
  
  return;
}


package PWUD::Download;

use strict;
use warnings;
use URI ();
use AE ();

use parent -norequire, 'PWUD';
BEGIN { PWUD->import(':require') }


sub get_links {
  my ($self) = @_;
  
  my $root = $self->{'_root'};
  my $table = $root->look_down( _tag => 'table' );
  
  if (defined $table) {
    my @items = $table->content_list();
    my @urls;
      
    for my $item (@items) {
      next if ($item->is_empty());
      
      if (my $url = $item->look_down(_tag => 'a')) {
        push @urls, $url->attr('href');
      }
    }
    
    return \@urls;
  }

  return $self->error( &E_TABLE() );
}

scalar "Silence";