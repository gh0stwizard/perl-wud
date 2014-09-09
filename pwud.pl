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

use Data::Dumper;

# Global variables
my $PIDFILE = $ENV{'PIDFILE'};
my $INPUT_FILE = $ENV{'FILE'};
my $DL_PATH = $ENV{'DL_PATH'};
my $DNS = $ENV{'DNS_SERVERS'};

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
    #FIXME: bug in ae:dns with multiple nameservers causes false-positive errors
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
  my $uri = URI->new($work_url);
  
  $data->{'url_work'} = $work_url;
  
  my $root = HTML::TreeBuilder->new_from_content($body);
  my $link_download = $root->look_down
  (
    _tag 	=> "a",
    class 	=> "mscom-link download-button dl",
  );
  
  my $link_details = $root->look_down
  (
    _tag	=> "a",
    class	=> "mscom-link mscom-accordion-item-link"
  );
  
  if (not defined $link_download) {
    AE::log error => "Failed to find download link: %s", $uri->as_iri;
    $data->{'error'} = "Failed to find download link";
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  if (not defined $link_details) {
    AE::log error => "Failed to find details link: %s", $uri->as_iri;
    $data->{'error'} = "Failed to find details link";
    $PROGRESS{$data->{'url_original'}} = 1;
    return;
  }
  
  my $uri_dl = URI->new_abs($link_download->attr('href'), $uri);
  my $uri_nfo = URI->new_abs($link_details->attr('href'), $uri);

  $data->{'url_dl'} = $uri_dl->as_string;
  $data->{'url_nfo'} = $uri_nfo->as_string;
  
  http_get $uri_nfo->as_string, sub {
    my ($body, $hdr) = @_;
    
    my $root = HTML::TreeBuilder->new_from_content($body);
    my $item = $root->look_down
    (
      _tag	=> "div",
      class	=> "fileinfo",
    );
    
    if (not defined $item) {
      AE::log error => "Failed to find file info: %s", $uri->as_iri;
      $data->{'error'} = "Failed to find file info";
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
    my @name_nodes = $filename->right->content_list;
    push @names, $_->as_text for @name_nodes;

    $data->{'file_size'} = \my @sizes;
    my @size_nodes = $filesize->right->content_list;
    push @sizes, $_->as_text for @size_nodes;
            
    my $kb_sb = $root->look_down
    (
      _tag	=> "div",
      class	=> "kb-sb",
    );
    
    if (not defined $kb_sb) {
      AE::log error => "Failed to find security bulletin: %s", $uri->as_iri;
      $data->{'error'} = "Failed to find security bulletin";
      $PROGRESS{$data->{'url_original'}} = 1;
      return;
    }
    
    my @items = $kb_sb->content_list;
    
    $data->{'kb-sb'} = \my @kb_sb;
    
    for my $item (@items) {
      next if ($item->is_empty());
      
      if (my $url = $item->look_down(_tag => 'a')) {
        #AE::log debug => "+ %s [%s]", $item->as_text, $url->attr('href');
        push @kb_sb, [$item->as_text(), $url->attr('href')];
      } else {
        #AE::log debug => "+ %s", $item->as_text;
        push @kb_sb, [$item->as_text()];
      }
    }
    
    http_get $uri_dl->as_string(), sub {
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
            
      &store_data($data);
      #AE::log debug => Dumper $data;
      $PROGRESS{$data->{'url_original'}} = 1;
    };
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
  
    printf FILE "URL: %s\n", $data->{'url_original'};
    printf FILE "File: %s\n", $data->{'file_name'}[$i];
    printf FILE "Size: %s\n", $data->{'file_size'}[$i];
    printf FILE "Version: %s\n", $data->{'file_version'};
    printf FILE "Date: %s\n", $data->{'date_publish'};
    printf FILE "Download: %s\n", $data->{'download'}[$i];
  
    printf FILE "References:\n";
    for my $info (@{ $data->{'kb-sb'} }) {
      next if (@$info != 2);
      printf FILE " %s\n", $info->[1];
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
