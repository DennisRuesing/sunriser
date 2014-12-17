package SunRiser::Simulator;
# ABSTRACT: SunRiser simulator application class

use MooX qw(
  Options
);

with 'SunRiser::Role::Logger';

sub _build__logger_category { 'SR_SIMULATOR' }

use AnyEvent;
use Twiggy::Server;
use Plack::Builder;
use Path::Tiny;
use File::ShareDir::ProjectDistDir;
use Plack::Util;
use HTTP::Date;
use Plack::Request;
use POSIX qw( floor );
use JSON::MaybeXS;
use File::Temp qw/ tempfile tempdir tmpnam /;
use bytes;
use Data::MessagePack;
use CDB::TinyCDB;
use SunRiser::Publisher;
use SunRiser::CDB;

option port => (
  is => 'ro',
  format => 'i',
  default => sub { 9000 },
  doc => 'port for the webserver',
);

option pwms => (
  is => 'ro',
  format => 'i',
  default => sub { 8 },
  doc => 'number of pwms on the SunRiser',
);

option password => (
  is => 'ro',
  format => 's',
  default => sub { 'test' },
  doc => 'password for login',
);

option changesdb => (
  is => 'ro',
  format => 's',
  short => 'c',
  default => sub { 'changes.cdb' },
  doc => 'CDB file for changed variable storage',
);

has changes_cdb => (
  is => 'lazy',
  handles => [qw(
    set
    save
  )],
);

sub _build_changes_cdb {
  my ( $self ) = @_;
  return SunRiser::CDB->new(
    filename => $self->changesdb,
    config => $self->config,
  );
}

option systemdb => (
  is => 'ro',
  format => 's@',
  predicate => 1,
  short => 's',
  doc => 'CDB file for read only system storages',
);

has system_cdbs => (
  is => 'lazy',
);

sub _build_system_cdbs {
  my ( $self ) = @_;
  return $self->has_systemdb ? [map { SunRiser::CDB->new(
    filename => $_,
    config => $self->config,
  )} @{$self->systemdb}] : [];
}

option no_fallback => (
  is => 'ro',
  format => 'i',
  default => sub { 0 },
  doc => 'Only use CDBs',
);

option webdir => (
  is => 'ro',
  format => 's',
  init_arg => 'web',
  doc => 'Directory to use for serving webfiles',
  default => sub { path(dist_dir('SunRiser'),'web')->stringify },
);

has w => (
  is => 'lazy',
  init_arg => undef,
);

sub _build_w {
  my ( $self ) = @_;
  my $w = path($self->webdir)->absolute->realpath;
  return $w;
}

has state => (
  is => 'lazy',
  init_arg => undef,
);

sub _build_state {
  my ( $self ) = @_;
  my $pwms = $self->pwms;
  return {
    # PWM name is a number but must be treated like a string
    pwms => [ map { $_."", 0 } 1..$pwms ]
  };
}

has cdbs => (
  is => 'lazy',
  init_arg => undef,
);

sub _build_cdbs {
  my ( $self ) = @_;
  return [
    $self->changes_cdb,
    (reverse @{$self->system_cdbs})
  ];
}

sub get {
  my ( $self, $key ) = @_;
  for my $cdb (@{$self->cdbs}) {
    return $cdb->get($key) if $cdb->exists($key);
  }
  return undef;
}

sub exists {
  my ( $self, $key ) = @_;
  for my $cdb (@{$self->cdbs}) {
    return 1 if $cdb->exists($key);
  }
  return 0;
}

sub _web_ok { $_[0]->debug("Sending OK"); [
  200,
  [ "Content-Type" => "text/plain" ],
  [ "OK" ]
]}

sub _web_forbidden { $_[0]->debug("Request forbidden"); [
  403,
  [ "Content-Type" => "text/plain" ],
  [ "FORBIDDEN" ]
]}

sub _web_unauthorized { $_[0]->debug("Request unauthorized"); [
  401,
  [ "Content-Type" => "text/plain" ],
  [ "UNAUTHORIZED" ]
]}

sub _web_notfound { $_[0]->debug("Not found"); [
  404,
  [ "Content-Type" => "text/plain" ],
  [ "NOT FOUND" ]
]}

sub _web_servererror { $_[0]->debug("Nothing todo, sending Internal Server Error"); [
  500,
  [ "Content-Type" => "text/plain" ],
  [ "INTERNAL SERVER ERROR" ]
]}

sub _web_serve_msgpack {
  my ( $self, $data, @headers ) = @_;
  my $msgpack = $self->_mp->pack($data);
  return [ 200, [
    'Content-Type' => 'application/x-msgpack',
    'Content-Length' => length($msgpack),
  ], [ $msgpack ] ];
}

sub _web_serve_file {
  my ( $self, $filename, @headers ) = @_;

  my $file = $self->w->child($filename);

  my ( $ext ) = $file =~ m/\.(\w+)$/;

  for my $pfile (($filename,$filename.'index.html',$filename.'/index.html')) {
    if ($self->has_publish_file($pfile)) {
      ( $ext ) = $pfile =~ m/\.(\w+)$/;
      my $tfile = tmpnam();
      $file = path($tfile);
      $file->spew_raw($self->render($pfile));
      last;
    }
  }

  unless (-f $file) {
    if (-d $file) {
      my $index = $file->child('index.html');
      if (-f $index) {
        $file = $index;
      } else {
        # Feature option: directory listing
        return $self->_web_notfound;        
      }
    } else {
      return $self->_web_notfound;
    }
  }

  my $content_type;
  my $parse = 0;

  unless ($content_type) {
    if ($ext eq 'html') {
      $content_type = 'text/html';
      $parse = 1;
    } elsif ($ext eq 'js') {
      $content_type = 'application/javascript';
    } elsif ($ext eq 'css') {
      $content_type = 'text/css';
    } elsif ($ext eq 'svg') {
      $content_type = 'image/svg+xml';
    } elsif ($ext eq 'woff') {
      $content_type = 'application/font-woff';
    } elsif ($ext eq 'ttf') {
      $content_type = 'application/x-font-ttf';
    } elsif ($ext eq 'gif') {
      $content_type = 'image/gif';
    } elsif ($ext eq 'jpg' || $ext eq 'jpeg') {
      $content_type = 'image/jpeg';
    } elsif ($ext eq 'png') {
      $content_type = 'image/png';
    } elsif ($ext eq 'json') {
      $content_type = 'application/json';
    } elsif ($ext eq 'webm') {
      $content_type = 'video/webm';
    } elsif ($ext eq 'flv') {
      $content_type = 'video/x-flv';
    } elsif ($ext eq 'pdf') {
      $content_type = 'application/pdf';
    } elsif ($ext eq 'zip') {
      $content_type = 'application/zip';
    } elsif ($ext eq 'ico') {
      $content_type = 'image/x-icon';
    } else {
      $content_type = 'text/plain'
    }
  }

  if ($content_type =~ m!^text/! or $content_type =~ m!/json$!) {
    $content_type .= "; charset=utf-8";
  }

  open my $fh, "<:raw", $file or return $self->_web_forbidden;
  my @stat = stat $file;
  Plack::Util::set_io_path($fh, Cwd::realpath($file));

  return [ 200, [
    'Content-Type' => $content_type,
    'Content-Length' => $stat[7],
    'Last-Modified'  => HTTP::Date::time2str( $stat[9] ),
    @headers
  ], $fh ];
}

sub _web_state {
  my ( $self ) = @_;
  $self->debug('Sending state');
  return $self->_web_serve_msgpack($self->state); 
}

sub _web_time {
  my ( $self ) = @_;
  $self->debug('Sending time');
  my $perl_time = time; # timestamp
  return $self->_web_serve_msgpack($perl_time);
}

has config => (
  is => 'lazy',
);

sub _build_config {
  my ( $self ) = @_;
  return SunRiser::Config->new;
}

has publisher => (
  is => 'lazy',
  init_arg => undef,
  handles => [qw(
    has_publish_file
    render
  )],
);

sub _build_publisher {
  my ( $self ) = @_;
  return SunRiser::Publisher->new(
    config => $self->config
  );
}

has _mp => (
  is => 'lazy',
  init_arg => undef,
);

sub _build__mp { Data::MessagePack->new->canonical->utf8->prefer_integer }

has web => (
  is => 'lazy',
  init_arg => undef,
);

sub _build_web {
  my ( $self ) = @_;
  my $sessionid = 12345678;
  $self->info('Starting webserver on port '.$self->port.'...');
  my $server = Twiggy::Server->new(
    port => $self->port,
  );
  $server->register_service(builder {
    enable sub {
      my $app = shift;
      sub {
        $self->debug('Web Request '.$_[0]->{REQUEST_METHOD}.' '.$_[0]->{PATH_INFO});
        my $res = $app->($_[0]);
        return $res;
      };
    };
    mount '/' => sub {
      my ( $env ) = @_;
      my $req = Plack::Request->new($env);

      my $method = uc($req->method);
      my $uri = $req->request_uri;
      $uri =~ s!/+!/!g; # remove double slashes

      # get cookie
      my $cookie = $req->headers->header('Cookie');

      my $logged_in = 0;
      # checking if cookie contains sid=$anysessionid stored in EPROM
      if ($cookie && $cookie =~ /sid=$sessionid/) {
        $logged_in = 1;
      }


      if ($uri eq '/') {
        # if logged in serve index.html
        if ($logged_in) {
          if ($method eq 'PUT') {
            my $body = $req->raw_body;
            my $data = $self->_mp->unpack($body);
            for my $k (keys %{$data}) {
              $self->set($k,$data->{$k});
            }
            $self->save;
            return $self->_web_ok;
          } elsif ($method eq 'POST') {
            my $body = $req->raw_body;
            my $data = $self->_mp->unpack($body);
            my %values;
            for my $key (@{$data}) {
              if ($self->exists($key)) {
                $values{$key} = $self->get($key);
              }
            }
            return $self->_web_serve_msgpack(\%values);
          } else {
            return $self->_web_serve_file('index.html');          
          }
        } else {
          # if POST check if body matches password=$password
          if ($method eq 'POST') {
            my $body = $req->raw_body;
            if ($body eq 'password='.$self->password) {
              # Set Cookie to newly generated sessionid from EPROM
              return $self->_web_serve_file('index.html',
                'Set-Cookie' => 'sid='.$sessionid
              );
            }
          }
          # if no post or password not accepted, show login.html
          return $self->_web_serve_file('login.html');
        }
      }

      if ($uri =~ /^\/logout(.*)$/) {
        # Trick to simulate logout with instead of deleting cookie
        # just garbage it with a wrong session id (safe method)
        return $self->_web_serve_file('login.html',
          'Set-Cookie' => 'sid=x'
        );
      }

      if ($method eq 'GET') {
        my ( $file ) = $uri =~ m/^\/([^\?]*)/;
        if ($uri =~ /^\/state/) {
          return $self->_web_state;
        } elsif ($uri =~ /^\/time/) {
          return $self->_web_time;
        }
        # else serve file from storage
        # gives back 200 on success and 404 on not found
        return $self->_web_serve_file($file);
      }

      # can't handle that request, send error
      return $self->_web_servererror;
    };
  });
  return $server;
}

sub BUILD {
  my ( $self ) = @_;
  $self->w;
  $self->web;
}

sub run {
  AE::cv->recv;
}

1;

=head1 DESCRIPTION

=head1 SUPPORT

Repository

  http://github.com/LEDaquaristik/sunriser
  Pull request and additional contributors are welcome
 
Issue Tracker

  http://github.com/LEDaquaristik/sunriser/issues

=cut
