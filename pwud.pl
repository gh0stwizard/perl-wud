#!perl

# Perl Windows Updates Downloader
#
# This is free software; you can redistribute it and/or modify it
# under the same terms as the Perl 5 programming language system itself.

use strict;
use warnings;

use common::sense;
use EV 4.0;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::HTTP;
use Time::HiRes qw/gettimeofday tv_interval/;
use HTML::TreeBuilder 5 -weak;
use Carp ();
use URI ();
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
}

sub process_response {
  my ($body, $hdr, $data) = @_;
  
  my $work_url = $hdr->{'URL'};
  my $status = $hdr->{'Status'};
  my $uri = URI->new($work_url);
    
  if ($status != 200) {
    AE::log error => "Failed to load page:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    AE::log error => " Status: %d Reason: %s", $status, $hdr->{'Reason'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  if ($hdr->{'content-disposition'} eq 'attachment') {
    AE::log error => "Invalid content type:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  $data->{'url_work'} = $work_url;
  
  my $root = HTML::TreeBuilder->new_from_content($body);
  my $product_title = $root->look_down
  (
    _tag	=> "div",
    class	=> "product-title",
  );
  
  if (not defined $product_title) {
    AE::log error => "Unable to parse content:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  my $title = $product_title->look_down(_tag => "h1");
  
  if (not defined $title) {
    AE::log error => "Failed to find title:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  $title = $title->as_text();
  $title =~ s/^\s+//;
  $title =~ s/\s+$//;
  
  $data->{'title'} = $title;
  
  my $link_download = $root->look_down
  (
    _tag 	=> "a",
    class 	=> "mscom-link download-button dl",
  );
  
  my $link_details = $root->look_down
  (
    _tag	=> "a",
    'bi:cmpnm'	=> 'Details',
  );
  
  my $link_required = $root->look_down
  (
    _tag	=> "a",
    'bi:cmpnm'	=> 'System Requirements',
  );
  
  if (not defined $link_download) {
    AE::log error => "Failed to find download link:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  if (not defined $link_details) {
    AE::log error => "Failed to find details link:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  if (not defined $link_required) {
    AE::log error => "Failed to find supported os:\n %s\n %s",
      $uri->as_iri(), $data->{'url_original'};
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  my $uri_dl = URI->new_abs( $link_download->attr('href'), $uri );
  my $uri_nfo = URI->new_abs( $link_details->attr('href'), $uri );
  my $uri_req = URI->new_abs( $link_required->attr('href'), $uri );

  $data->{'url_dl'} = $uri_dl->as_string();
  $data->{'url_nfo'} = $uri_nfo->as_string();
  $data->{'url_req'} = $uri_req->as_string();
  
  
  http_get $data->{'url_nfo'}, sub {
    my ($body, $hdr) = @_;
    
    my $root = HTML::TreeBuilder->new_from_content($body);
    my $item = $root->look_down
    (
      _tag	=> "div",
      class	=> "fileinfo",
    );
    
    if (not defined $item) {
      AE::log error => "Failed to find file info:\n %s\n %s",
        $uri->as_iri(), $data->{'url_original'};
      $PROGRESS{$data->{'url_original'}} = 1;
      return;
    }
    
    my $version = $item->look_down
    (
      _tag	=> "div",
      class	=> "header",
    );
    
    my ($filename, $filesize) = $item->look_down
    (
      _tag	=> "div",
      class	=> "file-header",
    );
    
    my $publish = $item->look_down
    (
      _tag	=> "div",
      class	=> "header date-published",
    );
    
    $data->{'file_version'} = $version->right->as_text();
    $data->{'date_publish'} = $publish->right->as_text();
    
    $data->{'file_name'} = \my @names;
    my @name_nodes = $filename->right->content_list();
    
    for (@name_nodes) {
      my $name = $_->as_text();
      $name =~ s/\\/\-/g;
      push @names, $name;
    }
    
    $data->{'file_size'} = \my @sizes;
    my @size_nodes = $filesize->right->content_list;
    push @sizes, $_->as_text for @size_nodes;
            
    my $kb_sb = $root->look_down
    (
      _tag	=> "div",
      class	=> "kb-sb",
    );
    
    if (defined $kb_sb) {
      my @items = $kb_sb->content_list;
    
      $data->{'kb-sb'} = \my @kb_sb;
    
      for my $item (@items) {
        next if ($item->is_empty());
      
        if (my $url = $item->look_down(_tag => 'a')) {
          push @kb_sb, [$item->as_text(), $url->attr('href')];
        } else {
          push @kb_sb, [$item->as_text()];
        }
      }
    } else {
      AE::log warn => "Failed to find security bulletin:\n %s\n %s",
        $uri->as_iri(), $data->{'url_original'};
    }
    
    http_get $data->{'url_req'}, sub {
      my ($body, $hdr) = @_;
      
      my $root = HTML::TreeBuilder->new_from_content($body);
      my $info = $root->look_down
      (
        _tag		=> "p",
        itemprop	=> "operatingSystem",
      );
      
      if (defined $info) {
        $data->{'required'} = $info->as_text();
      } else {
        AE::log warn => "Failed to find requirements:\n %s\n %s",
          $uri->as_iri(), $data->{'url_original'};
      }

      http_get $data->{'url_dl'}, sub {
        my ($body, $hdr) = @_;
    
        my $root = HTML::TreeBuilder->new_from_content($body);
        my $table = $root->look_down(_tag	=> 'table');
        my @items = $table->content_list;
      
        $data->{'download'} = \my @urls;
      
        for my $item (@items) {
          next if ($item->is_empty());
        
          if (my $url = $item->look_down(_tag => 'a')) {
            push @urls, $url->attr('href');
          }
        }
        
        if (not $DRY_RUN) {
          &store_data($data);
        }
        
        $PROGRESS{$data->{'url_original'}} = 1;
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
