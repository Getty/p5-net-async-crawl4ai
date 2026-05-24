package Net::Async::Crawl4AI;
# ABSTRACT: IO::Async Crawl4AI client with an async strategy chain
use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Carp qw( croak );
use Scalar::Util qw( blessed );
use Time::HiRes ();
use WWW::Crawl4AI ();
use WWW::Crawl4AI::Request ();
use WWW::Crawl4AI::Result ();
use WWW::Crawl4AI::Error ();
use Net::Async::HTTP ();
use Future ();
use Future::Utils qw( repeat );

our $VERSION = '0.001';

# Keys forwarded straight to the underlying WWW::Crawl4AI orchestrator.
my @WWW_KEYS = qw(
  base_url api_token cloakbrowser_url proxy_url callback
  fallback timeout min_markdown client
);

sub _init {
  my ( $self, $args ) = @_;
  $self->SUPER::_init($args);
  $self->{crawl4ai} = delete $args->{crawl4ai} if exists $args->{crawl4ai};
  $self->{crawl4ai} ||= WWW::Crawl4AI->new(
    map { exists $args->{$_} ? ( $_ => delete $args->{$_} ) : () } @WWW_KEYS
  );
  $self->{poll_interval} = exists $args->{poll_interval} ? delete $args->{poll_interval} : 2;
  $self->{http}      = delete $args->{http};
  $self->{delay_sub} = delete $args->{delay_sub};
  return;
}

sub configure_unknown {
  my ( $self, %args ) = @_;
  delete @args{ @WWW_KEYS, qw( crawl4ai poll_interval http delay_sub ) };
  return unless %args;
  croak "Unknown configuration keys: " . join( ',', sort keys %args );
}

sub crawl4ai          { $_[0]->{crawl4ai} }
sub client            { $_[0]->{crawl4ai}->client }
sub poll_interval     { @_ > 1 ? ( $_[0]->{poll_interval} = $_[1] ) : $_[0]->{poll_interval} }
sub available_backends { $_[0]->{crawl4ai}->available_backends }

sub http {
  my ( $self ) = @_;
  return $self->{http} if $self->{http};
  my $http = Net::Async::HTTP->new(
    user_agent               => $self->client->user_agent_string,
    max_connections_per_host => 4,
  );
  $self->add_child($http);
  return $self->{http} = $http;
}

sub _on_added_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_on_added_to_loop($loop) if $self->can('SUPER::_on_added_to_loop');
  $self->http;
}

#----------------------------------------------------------------------
# Request dispatch + retry (Future-based mirror of the client's policy)
#----------------------------------------------------------------------

sub _delay_future {
  my ( $self, $seconds ) = @_;
  return $self->{delay_sub}->($seconds) if $self->{delay_sub};
  return $self->loop->delay_future( after => $seconds );
}

sub do_request {
  my ( $self, $request, $backend ) = @_;
  croak "do_request requires an HTTP::Request" unless $self->client->is_request($request);
  return $self->_do_request_with_retry( $request, $backend, 1 );
}

sub _retry_delay {
  my ( $self, $attempt, $response ) = @_;
  my $backoff = $self->client->retry_backoff;
  my $delay = $backoff->[ $attempt - 1 ] // $backoff->[-1] // 1;
  if ( $response && ( my $ra = $response->header('Retry-After') ) ) {
    $delay = $ra if $ra =~ /^\d+$/;
  }
  return $delay;
}

sub _do_request_with_retry {
  my ( $self, $request, $backend, $attempt ) = @_;
  my $client = $self->client;
  my $max    = $client->max_attempts;
  return $self->http->do_request( request => $request, fail_on_error => 0 )->then(
    sub {
      my ( $response ) = @_;
      return Future->done($response) if $response->is_success;
      my $code      = $response->code;
      my $retryable = $client->_retry_status_set->{$code};
      if ( $retryable && $attempt < $max ) {
        my $delay = $self->_retry_delay( $attempt, $response );
        $client->on_retry->( $attempt, $delay, $response ) if $client->on_retry;
        return $self->_delay_future($delay)
          ->then( sub { $self->_do_request_with_retry( $request, $backend, $attempt + 1 ) } );
      }
      # Non-retryable / exhausted non-2xx: hand the response back so the
      # endpoint's parser raises the proper api error (with status_code).
      return Future->done($response);
    },
    sub {
      my ( $err ) = @_;    # transport-level failure from Net::Async::HTTP
      if ( $attempt < $max ) {
        my $delay = $self->_retry_delay( $attempt, undef );
        $client->on_retry->( $attempt, $delay, $err ) if $client->on_retry;
        return $self->_delay_future($delay)
          ->then( sub { $self->_do_request_with_retry( $request, $backend, $attempt + 1 ) } );
      }
      return Future->fail(
        WWW::Crawl4AI::Error->new(
          type        => 'transport',
          message     => "Crawl4AI transport error: $err",
          status_code => 0,
          backend     => $backend,
          attempt     => $attempt,
        ),
        'crawl4ai',
      );
    },
  );
}

# Dispatch $http_req, then run $parse->($response). Parser exceptions become a
# failed Future carrying a WWW::Crawl4AI::Error.
sub _parsed {
  my ( $self, $http_req, $parse, $backend ) = @_;
  return $self->do_request( $http_req, $backend )->then( sub {
    my ( $res ) = @_;
    my $out = eval { $parse->($res) };
    if ( my $e = $@ ) {
      my $err = ( blessed($e) && $e->isa('WWW::Crawl4AI::Error') )
        ? $e
        : WWW::Crawl4AI::Error->new(
            type => 'api', message => "$e", response => $res, backend => $backend );
      return Future->fail( $err, 'crawl4ai' );
    }
    return Future->done($out);
  } );
}

#----------------------------------------------------------------------
# Low-level Future endpoints
#----------------------------------------------------------------------

sub crawl_once {
  my ( $self, $request, $backend ) = @_;
  my $client = $self->client;
  return $self->_parsed(
    $client->crawl_request($request),
    sub { $client->parse_crawl_response( $_[0], $backend ) },
    $backend,
  );
}

sub md {
  my ( $self, $url, %opts ) = @_;
  my $client  = $self->client;
  my $request = ( blessed($url) && $url->isa('WWW::Crawl4AI::Request') )
    ? $url
    : WWW::Crawl4AI::Request->new( urls => $url, %opts );
  return $self->_parsed(
    $client->md_request($request),
    sub { $client->parse_md_response( $_[0] ) },
  );
}

sub job_submit {
  my ( $self, $request ) = @_;
  my $client = $self->client;
  return $self->_parsed(
    $client->job_submit_request($request),
    sub { $client->parse_job_submit_response( $_[0] ) },
  );
}

sub job_status {
  my ( $self, $task_id ) = @_;
  my $client = $self->client;
  return $self->_parsed(
    $client->job_status_request($task_id),
    sub { $client->parse_job_status_response( $_[0] ) },
  );
}

sub health {
  my ( $self ) = @_;
  my $client = $self->client;
  return $self->do_request( $client->health_request )->then(
    sub { Future->done( $client->parse_health_response( $_[0] ) ? 1 : 0 ) },
    sub { Future->done(0) },
  );
}

#----------------------------------------------------------------------
# Job flow helper
#----------------------------------------------------------------------

sub crawl_job_and_wait {
  my ( $self, $request, %opts ) = @_;
  my $interval = delete $opts{poll_interval};
  my $req = ( blessed($request) && $request->isa('WWW::Crawl4AI::Request') )
    ? $request
    : WWW::Crawl4AI::Request->new( urls => $request, %opts );
  return $self->job_submit($req)->then( sub {
    my ( $job ) = @_;
    $self->_poll_job( $job->{task_id}, $interval );
  } );
}

sub _poll_job {
  my ( $self, $task_id, $interval ) = @_;
  $interval = $self->poll_interval unless defined $interval;
  croak "not added to a loop yet" unless $self->loop || $self->{delay_sub};
  return repeat {
    $self->job_status($task_id)->then( sub {
      my ( $status ) = @_;
      return Future->done($status) if ( $status->{status} // '' ) eq 'COMPLETED';
      return $self->_delay_future($interval)->then( sub { Future->done($status) } );
    } );
  } until => sub {
    my ( $f ) = @_;
    return 1 if $f->is_failed;    # parser fails the Future on a FAILED job
    return ( $f->get->{status} // '' ) eq 'COMPLETED';
  };
}

#----------------------------------------------------------------------
# Async strategy chain — the headline async API
#----------------------------------------------------------------------

sub _elapsed { sprintf( '%.3f', Time::HiRes::time() - $_[0] ) + 0 }

# Run a single strategy asynchronously, resolving to a normalized page (or
# undef). crawl4ai-backed strategies dispatch through Net::Async::HTTP; the
# external_callback strategy hands the URL to the user coderef, which may return
# a hashref or a Future of one.
sub _run_strategy_future {
  my ( $self, $strategy, $url, %opts ) = @_;
  my $www = $self->crawl4ai;

  if ( $strategy->can('build_request') ) {
    my $req = $strategy->build_request( $www, $url, %opts );
    return $self->crawl_once( $req, $strategy->name )->then( sub { Future->done( $_[0]->[0] ) } );
  }

  if ( $strategy->name eq 'external_callback' ) {
    my $ret = $www->callback->( $url, %opts );
    my $normalize = sub {
      my ( $page ) = @_;
      return undef unless ref $page eq 'HASH';
      $page->{url}       //= $url;
      $page->{final_url} //= $page->{url};
      return $page;
    };
    return $ret->then( sub { Future->done( $normalize->( $_[0] ) ) } )
      if blessed($ret) && $ret->isa('Future');
    return Future->done( $normalize->($ret) );
  }

  # Any other custom strategy: run its sync crawl, allowing a Future return.
  my $page = $strategy->crawl( $www, $url, %opts );
  return $page if blessed($page) && $page->isa('Future');
  return Future->done($page);
}

sub crawl {
  my ( $self, @args ) = @_;
  my $www = $self->crawl4ai;
  my ( $url, %opts ) = $www->_normalize_args(@args);
  croak "crawl needs a url" unless defined $url && length $url;

  my $detect     = $www->_detect_opts(%opts);
  my @strategies = @{ $www->strategies };
  return Future->done( $www->_failed_result( $url, [] ) ) unless @strategies;

  my @attempts;
  my $i = 0;
  return (
    repeat {
      my $strategy = $strategies[ $i++ ];
      my $t0       = Time::HiRes::time();
      $self->_run_strategy_future( $strategy, $url, %opts )->then(
        sub {
          push @attempts, $www->_attempt_for( $strategy, $_[0], undef, _elapsed($t0), $detect );
          Future->done( $attempts[-1] );
        },
        sub {
          push @attempts, $www->_attempt_for( $strategy, undef, $_[0], _elapsed($t0), $detect );
          Future->done( $attempts[-1] );
        },
      );
    } while => sub {
      my $attempt = $_[0]->get;
      return 0 if $attempt->ok;
      return $i < @strategies ? 1 : 0;
    }
  )->then( sub {
    my ( $winner ) = grep { $_->ok } @attempts;
    return Future->done(
      $winner
      ? WWW::Crawl4AI::Result->from_attempt( $winner, attempts => \@attempts )
      : $www->_failed_result( $url, \@attempts )
    );
  } );
}

sub markdown { my ( $self, @args ) = @_; return $self->crawl(@args) }

1;

=head1 SYNOPSIS

  use IO::Async::Loop;
  use Net::Async::Crawl4AI;

  my $loop = IO::Async::Loop->new;
  my $crawler = Net::Async::Crawl4AI->new(
    base_url         => 'http://localhost:11235',
    cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},   # optional
    poll_interval    => 2,
  );
  $loop->add($crawler);

  # Async strategy chain — escalates plain -> browser -> stealth -> ...
  my $result = $crawler->markdown('https://example.com')->get;
  say $result->markdown;
  say $result->backend;        # crawl4ai_plain / crawl4ai_stealth / ...
  say $result->attempts_json;

  # Low-level single crawl (no chain), returns all pages.
  my $pages = $crawler->crawl_once(
    WWW::Crawl4AI::Request->new( urls => 'https://example.com' )
  )->get;

  # Submit an async crawl job and poll it to completion.
  my $done = $crawler->crawl_job_and_wait('https://example.com')->get;
  # { status => 'COMPLETED', pages => [...], raw => {...} }

=head1 DESCRIPTION

L<IO::Async>-flavoured companion to L<WWW::Crawl4AI>. It wraps a
L<WWW::Crawl4AI> orchestrator, dispatches its request builders through
L<Net::Async::HTTP>, and returns L<Future> objects — including a fully
asynchronous run of the same B<visible strategy chain>.

The pure building blocks (request building, page normalization, content
classification via L<WWW::Crawl4AI::Detect>, and L<WWW::Crawl4AI::Attempt> /
L<WWW::Crawl4AI::Result> history) are shared with the synchronous
L<WWW::Crawl4AI>, so C<< $crawler->markdown(...)->get >> produces the same
L<WWW::Crawl4AI::Result> the sync facade would — only non-blocking.

=head1 CONSTRUCTOR PARAMETERS

=over 4

=item * C<base_url>, C<api_token>, C<cloakbrowser_url>, C<proxy_url>, C<callback>, C<fallback>, C<timeout>, C<min_markdown>, C<client> — forwarded to L<WWW::Crawl4AI>.

=item * C<crawl4ai> — pass a pre-built L<WWW::Crawl4AI> instance (overrides the keys above).

=item * C<http> — pass a pre-built L<Net::Async::HTTP> (otherwise one is created and parented to this notifier).

=item * C<poll_interval> — seconds between job-status polls (default 2).

=item * C<delay_sub> — optional CodeRef returning a L<Future> for retry/poll delays. Defaults to C<< $loop->delay_future >>. Mainly a test hook.

=back

The retry policy (C<max_attempts>, C<retry_backoff>, C<retry_statuses>,
C<on_retry>) lives on the underlying L<WWW::Crawl4AI::Client>; this module's
async dispatch honours it via L</delay_sub>.

=head1 ERROR HANDLING

Endpoint Futures fail as C<< Future->fail($error, 'crawl4ai') >> where
C<$error> is a L<WWW::Crawl4AI::Error>. C<crawl>/C<markdown> never fail for
per-strategy errors: each failed strategy becomes an entry in the result's
attempt history, and an all-strategies-failed run resolves to a
L<WWW::Crawl4AI::Result> with C<< ok => 0 >>.

=method markdown

=method crawl

  my $result = $crawler->markdown('https://example.com')->get;
  my $result = $crawler->crawl( url => 'https://example.com' )->get;

Run the strategy chain asynchronously and resolve to a
L<WWW::Crawl4AI::Result>. Same chain, same result object as the synchronous
L<WWW::Crawl4AI/markdown>. Accepts a single positional URL or named arguments
with a C<url> key.

=method crawl_once($request, $backend?)

Low-level single C<POST /crawl>. Resolves to the arrayref of normalized pages
(no chain, no classification). C<$request> is a L<WWW::Crawl4AI::Request> or a
payload hashref.

=method md($url_or_request, %opts)

C<POST /md>. Resolves to the markdown payload.

=method job_submit($request)

C<POST /crawl/job>. Resolves to C<< { task_id, raw } >>.

=method job_status($task_id)

C<GET /crawl/job/$task_id>. Resolves to C<< { status, pages, raw } >>; fails
with a C<type=job> L<WWW::Crawl4AI::Error> when the job reports C<FAILED>.

=method crawl_job_and_wait($url_or_request, %opts)

Submits a crawl job and polls C<job_status> every C<poll_interval> seconds
(override per call with C<< poll_interval => N >>) until it reports
C<COMPLETED>. Resolves to the final status hash; fails C<type=job> on a failed
job.

=method health

Resolves to 1 if the Crawl4AI server answers C<GET /health>, else 0. Never
fails.

=method do_request($http_request, $backend?)

Low-level: dispatch an L<HTTP::Request> (typically built via
C<< $self->client->foo_request >>) through L<Net::Async::HTTP> with the retry
policy applied. Returns a Future of L<HTTP::Response>.

=method crawl4ai

The underlying L<WWW::Crawl4AI> orchestrator.

=method client

The underlying L<WWW::Crawl4AI::Client> (used for request builders, response
parsers and retry configuration).

=method http

The underlying L<Net::Async::HTTP> (lazily built and parented to this notifier).

=method poll_interval

Read/write accessor for the default job-status poll interval (seconds).

=method available_backends

Arrayref of backend names currently in the chain.

=seealso

L<WWW::Crawl4AI>, L<WWW::Crawl4AI::Client>, L<WWW::Crawl4AI::Result>,
L<IO::Async>, L<Net::Async::HTTP>, L<Future>,
L<https://github.com/unclecode/crawl4ai>

=cut
