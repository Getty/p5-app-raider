package App::Raider::Hall::ACP;
our $VERSION = '0.004';
# ABSTRACT: ACP (Agent Client Protocol) adapter — exposes the hall over TCP

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Socket::IP;
use JSON::MaybeXS;

=head1 DESCRIPTION

Minimal ACP server. Speaks JSON-RPC 2.0 line-framed over TCP. Clients
(Zed, future ACP-capable editors) connect to the configured port and
drive raiders through the hall.

=head2 Supported methods

=over

=item * C<initialize> — handshake. Returns C<protocolVersion> and
C<agentCapabilities> (promptCapabilities: image=false, audio=false,
embeddedContext=false).

=item * C<session/new> — create a session bound to a raider slot.
Params: C<{ cwd, mcpServers?, raiderName? }>. If C<raiderName> is given
it selects the configured raider; otherwise the first entry in
C<.raider-hall.yml> is used.

=item * C<session/prompt> — spawn the raider with the user turn's text
content, stream C<session/update> notifications from the hall event bus,
return C<{ stopReason }> when the raider finishes.

=item * C<session/cancel> — send the raider a TERM.

=back

Features intentionally omitted in this first cut: authentication,
filesystem push-edits, embedded context resources, audio/image content
blocks. Calls unknown to this adapter return JSON-RPC error
C<-32601 method not found>.

=cut

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has port => (
  is => 'ro',
  isa => 'Int',
  default => 0,
);

has host => (
  is => 'ro',
  isa => 'Str',
  default => '127.0.0.1',
);

has _sessions => (
  is => 'ro',
  default => sub { {} },
);

has _listener => (
  is => 'rw',
);

our $PROTOCOL_VERSION = 1;

sub start {
  my ($self) = @_;
  my $loop = $self->hall->loop;

  my $sock = IO::Socket::IP->new(
    LocalHost => $self->host,
    LocalPort => $self->port,
    Listen    => 10,
    ReuseAddr => 1,
  ) or die "ACP: cannot listen on " . $self->host . ":" . $self->port . ": $!";

  my $listener = IO::Async::Listener->new(
    on_accept => sub {
      my ($l, $client) = @_;
      $self->_handle_client($client);
    },
  );
  $loop->add($listener);
  $listener->listen(handle => $sock);
  $self->_listener($listener);

  my ($port) = $sock->sockport;
  $self->hall->_emit('acp.started', {
    host => $self->host, port => $port,
  });
  return $port;
}

sub stop {
  my ($self) = @_;
  my $l = $self->_listener or return;
  eval { $self->hall->loop->remove($l) };
  $self->_listener(undef);
}

sub _handle_client {
  my ($self, $sock) = @_;
  my $stream = IO::Async::Stream->new(
    handle  => $sock,
    on_read => sub {
      my ($stream, $bufref, $eof) = @_;
      while ($$bufref =~ s/^(.*?)\r?\n//) {
        $self->_dispatch($stream, $1);
      }
      return 0;
    },
    on_closed => sub {
      my ($stream) = @_;
      # Clean up any sessions bound to this stream.
      for my $sid (keys %{$self->_sessions}) {
        my $s = $self->_sessions->{$sid};
        delete $self->_sessions->{$sid}
          if $s && $s->{stream} && $s->{stream} == $stream;
      }
    },
  );
  $self->hall->loop->add($stream);
}

sub _dispatch {
  my ($self, $stream, $line) = @_;
  return unless length $line;

  my $msg = eval { JSON::MaybeXS->new->decode($line) };
  if ($@ || ref $msg ne 'HASH') {
    return $self->_reply_err($stream, undef, -32700, 'parse error');
  }

  my $method = $msg->{method};
  my $id     = $msg->{id};
  my $params = $msg->{params} // {};

  if (!defined $method) {
    # It's a response to something we sent — ignore, we don't call out
    # mid-stream in this minimal adapter.
    return;
  }

  if ($method eq 'initialize') {
    return $self->_reply($stream, $id, {
      protocolVersion => $PROTOCOL_VERSION,
      agentCapabilities => {
        loadSession => JSON::MaybeXS::false(),
        promptCapabilities => {
          image           => JSON::MaybeXS::false(),
          audio           => JSON::MaybeXS::false(),
          embeddedContext => JSON::MaybeXS::false(),
        },
      },
    });
  }

  if ($method eq 'session/new') {
    return $self->_session_new($stream, $id, $params);
  }

  if ($method eq 'session/prompt') {
    return $self->_session_prompt($stream, $id, $params);
  }

  if ($method eq 'session/cancel') {
    return $self->_session_cancel($stream, $id, $params);
  }

  return $self->_reply_err($stream, $id, -32601, "method not found: $method");
}

sub _session_new {
  my ($self, $stream, $id, $params) = @_;

  my $raider_name = $params->{raiderName};
  if (!$raider_name) {
    my $raiders = $self->hall->config->{raiders} // {};
    ($raider_name) = sort keys %$raiders;
  }
  if (!$raider_name) {
    return $self->_reply_err($stream, $id, -32602,
      'no raiders configured and none specified');
  }

  my $session_id = 'acp-' . sprintf('%08x', int(rand(2**32)));
  $self->_sessions->{$session_id} = {
    stream => $stream,
    raider_name => $raider_name,
    current_raider_id => undef,
  };

  $self->_reply($stream, $id, { sessionId => $session_id });
}

sub _session_prompt {
  my ($self, $stream, $id, $params) = @_;

  my $session_id = $params->{sessionId}
    or return $self->_reply_err($stream, $id, -32602, 'missing sessionId');
  my $session = $self->_sessions->{$session_id}
    or return $self->_reply_err($stream, $id, -32602, "unknown session: $session_id");

  # Flatten the prompt content into text.
  my @blocks = @{ $params->{prompt} // [] };
  my $text = join("\n", map {
    my $b = $_;
    ref $b eq 'HASH' && defined $b->{text} ? $b->{text} : ''
  } @blocks);
  $text =~ s/^\s+|\s+$//g;
  return $self->_reply_err($stream, $id, -32602, 'empty prompt') unless length $text;

  my $spawn = $self->hall->spawn(
    name => $session->{raider_name},
    mission => $text,
  );
  if ($spawn->{error}) {
    return $self->_reply_err($stream, $id, -32000, "spawn failed: $spawn->{error}");
  }

  # Queued (1name busy) — report and return an intermediate stop reason.
  if ($spawn->{queued}) {
    return $self->_reply($stream, $id, { stopReason => 'queued' });
  }

  my $raider_id = $spawn->{id};
  $session->{current_raider_id} = $raider_id;
  $session->{pending_request_id} = $id;

  # Subscribe this session's stream to hall events for this raider.
  # We reuse the hall's subscriber list but filter in _on_hall_event.
  $self->_attach_subscription($session, $raider_id, $stream);
}

sub _attach_subscription {
  my ($self, $session, $raider_id, $stream) = @_;
  my $hall = $self->hall;

  my $handler = sub {
    my ($evt) = @_;
    my $t = $evt->{type} // '';
    return unless $t =~ /^raider\./;
    return unless ($evt->{id} // '') eq $raider_id;

    if ($t eq 'raider.done') {
      # The raider was spawned with --json, so its captured log is a
      # single JSON blob { response, metrics, elapsed }. Read it and
      # forward the actual response as a final agent_message_chunk
      # before closing the turn — otherwise the client only ever sees
      # status events.
      my $body = $self->_read_raider_response($raider_id);
      if (defined $body && length $body) {
        $self->_notify($stream, 'session/update', {
          sessionId => $self->_session_id_for($session),
          update => {
            sessionUpdate => 'agent_message_chunk',
            content => { type => 'text', text => $body },
          },
        });
      }
      my $rid = delete $session->{pending_request_id};
      $self->_reply($stream, $rid, {
        stopReason => $evt->{signaled} ? 'cancelled' : 'end_turn',
      }) if defined $rid;
    }
    elsif ($t eq 'raider.failed') {
      my $rid = delete $session->{pending_request_id};
      $self->_reply($stream, $rid, { stopReason => 'refusal' }) if defined $rid;
    }
    else {
      # Forward other raider.* events as plaintext chunks so clients get
      # *some* streaming. A richer mapping (tool_call → tool_use update
      # etc.) can grow from here.
      my $chunk = JSON::MaybeXS->new(canonical => 1)->encode({
        type => $t, ($evt->{data} ? (data => $evt->{data}) : ()),
      });
      $self->_notify($stream, 'session/update', {
        sessionId => $self->_session_id_for($session),
        update => {
          sessionUpdate => 'agent_message_chunk',
          content => { type => 'text', text => $chunk },
        },
      });
    }
  };

  # Piggy-back on the hall subscriber bus with a synthetic "stream" that
  # is actually our callback. The hall writes JSON+\n into ->write, so
  # we wrap it.
  my $fake_stream = App::Raider::Hall::ACP::SubStream->new(cb => sub {
    my ($json_line) = @_;
    my $evt = eval { JSON::MaybeXS->new->decode($json_line) };
    return if $@;
    $handler->($evt);
  });
  push @{ $hall->{_subscribers} ||= [] }, {
    stream => $fake_stream, filter => 'raider.',
  };
  $session->{_sub_stream} = $fake_stream;
}

sub _read_raider_response {
  my ($self, $raider_id) = @_;
  # Raiders live in the hall for a moment after raider.done fires; grab
  # the log path while the record is still there.
  my $raider;
  for my $r (values %{ $self->hall->raiders }) {
    if ($r->id eq $raider_id) { $raider = $r; last }
  }
  return unless $raider;
  my $log = $raider->log_path;
  return unless -f $log;
  my $raw = eval { $log->slurp_utf8 };
  return unless defined $raw && length $raw;
  my $data = eval { JSON::MaybeXS->new->decode($raw) };
  return $raw unless ref $data eq 'HASH';  # not JSON? forward verbatim
  return $data->{response} // $data->{error};
}

sub _session_id_for {
  my ($self, $session) = @_;
  for my $sid (keys %{$self->_sessions}) {
    return $sid if $self->_sessions->{$sid} == $session;
  }
  return '';
}

sub _session_cancel {
  my ($self, $stream, $id, $params) = @_;
  my $session_id = $params->{sessionId}
    or return $self->_reply_err($stream, $id, -32602, 'missing sessionId');
  my $session = $self->_sessions->{$session_id}
    or return $self->_reply_err($stream, $id, -32602, "unknown session: $session_id");

  if (my $rid = $session->{current_raider_id}) {
    $self->hall->kill_raider($rid);
  }
  $self->_reply($stream, $id, {});
}

sub _reply {
  my ($self, $stream, $id, $result) = @_;
  return unless defined $id;
  my $msg = { jsonrpc => '2.0', id => $id, result => $result };
  $stream->write(JSON::MaybeXS->new->encode($msg) . "\n");
}

sub _reply_err {
  my ($self, $stream, $id, $code, $message) = @_;
  return unless defined $id;
  my $msg = { jsonrpc => '2.0', id => $id, error => { code => $code, message => $message } };
  $stream->write(JSON::MaybeXS->new->encode($msg) . "\n");
}

sub _notify {
  my ($self, $stream, $method, $params) = @_;
  my $msg = { jsonrpc => '2.0', method => $method, params => $params };
  $stream->write(JSON::MaybeXS->new->encode($msg) . "\n");
}

__PACKAGE__->meta->make_immutable;

1;

# Tiny shim so the hall's subscriber loop can push JSON+\n into a
# callback instead of an IO::Async::Stream handle.
package App::Raider::Hall::ACP::SubStream;
our $VERSION = '0.004';

sub new {
  my ($class, %args) = @_;
  bless { cb => $args{cb}, opened => 1 }, $class;
}
sub write {
  my ($self, $line) = @_;
  chomp(my $l = $line);
  $self->{cb}->($l);
  return 1;
}
sub handle { $_[0] }
sub opened { $_[0]->{opened} }

1;
